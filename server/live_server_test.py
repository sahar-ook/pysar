#!/usr/bin/env python3
"""Tests for server/live_server.py that need no network: the WAV header walk,
reading a file that is still growing, chunking, the stop sequence against
a fake Live socket, and the free key falling back to the paid one.

  python3 -I server/live_server_test.py
"""
import base64, json, os, struct, sys, tempfile, threading, time, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live_server as ls  # noqa: E402


def fmt_chunk(rate=16000, channels=1, bits=16):
    return b"fmt " + struct.pack("<IHHIIHH", 16, 1, channels, rate, rate * channels * bits // 8,
                                 channels * bits // 8, bits)


def header(extra=b"", rate=16000, data_size=0x7FFFF000):
    body = b"WAVE" + fmt_chunk(rate) + extra + b"data" + struct.pack("<I", data_size)
    return b"RIFF" + struct.pack("<I", 0x7FFFF024) + body


class DataOffset(unittest.TestCase):
    def test_plain_sox_header(self):
        self.assertEqual(ls.data_offset(header()), 44)

    def test_list_chunk_before_data(self):
        info = b"INFOISFT" + struct.pack("<I", 14) + b"Lavf58.76.100\x00"
        self.assertEqual(ls.data_offset(header(b"LIST" + struct.pack("<I", len(info)) + info)), 44 + 8 + len(info))

    def test_odd_chunk_is_padded(self):
        odd = b"junk" + struct.pack("<I", 3) + b"abc" + b"\x00"
        self.assertEqual(ls.data_offset(header(odd)), 44 + len(odd))

    def test_truncated_header_waits(self):
        full = header()
        for n in (0, 4, 11, 12, 20, 30, 36, 40, 43):
            self.assertIsNone(ls.data_offset(full[:n]), n)

    def test_not_a_wav(self):
        with self.assertRaises(ValueError):
            ls.data_offset(b"ID3\x03" + b"\x00" * 40)

    def test_wrong_rate(self):
        with self.assertRaises(ValueError):
            ls.data_offset(header(rate=44100))


class Reading(unittest.TestCase):
    def test_split(self):
        self.assertEqual([len(c) for c in ls.split(b"x" * 7000)], [3200, 3200, 600])
        self.assertEqual(ls.split(b""), [])

    def test_tail_of_a_growing_file(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "take.wav")
        tail = ls.Tail(path)
        self.assertEqual(tail.read(), b"")                  # sox has not created it yet
        with open(path, "wb") as f:
            f.write(header()[:30]); f.flush()
            self.assertEqual(tail.read(), b"")              # half a header
            f.write(header()[30:]); f.flush()
            self.assertEqual(tail.read(), b"")              # header, no audio
            f.write(b"\x01" * 1001); f.flush()
            self.assertEqual(tail.read(), b"\x01" * 1000)   # never half a sample
            f.write(b"\x02"); f.flush()
            self.assertEqual(tail.read(), b"\x01\x02")
        os.remove(path); os.rmdir(d)


class FakeWS:
    """Answers the setup after `setup_delay`, and after activityEnd delivers `after_end`."""

    def __init__(self, setup_delay=0.0, after_end=(), interim=None):
        self.sent, self.queue, self.closed_by_us = [], [], False
        self.setup_delay, self.after_end, self.interim = setup_delay, after_end, interim
        self.lock = threading.Lock()

    def _later(self, delay, item):
        with self.lock:
            self.queue.append((time.time() + delay, item))

    def send(self, obj):
        self.sent.append(obj)
        if "setup" in obj:
            self._later(self.setup_delay, ("msg", json.dumps({"setupComplete": {}}).encode()))
        ri = obj.get("realtimeInput", {})
        if "audio" in ri and self.interim:
            self._later(0, ("msg", json.dumps({"serverContent": {"interimInputTranscription": {"text": self.interim}}}).encode()))
        if "activityEnd" in ri:
            for i, item in enumerate(self.after_end):
                self._later(0.05 + 0.01 * i, item)

    def recv(self, timeout):
        end = time.time() + timeout
        while True:
            with self.lock:
                due = [it for at, it in self.queue if at <= time.time()]
                self.queue = [(at, it) for at, it in self.queue if at > time.time()]
            if due or time.time() >= end:
                return due
            time.sleep(0.005)

    def close(self):
        self.closed_by_us = True


def msg(obj):
    return ("msg", json.dumps(obj, ensure_ascii=False).encode())


FINAL = msg({"serverContent": {"inputTranscription": {"text": "Перенеси дзвінок з Тарасом на 27 жовтня."}}})
DONE = msg({"serverContent": {"generationComplete": True}})


class StopSequence(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.wav = os.path.join(self.dir, "take-1.wav")
        self.pcm = bytes(range(256)) * 50   # 12 800 bytes, 0.4 s
        with open(self.wav, "wb") as f:
            f.write(header() + self.pcm)

    def tearDown(self):
        os.remove(self.wav); os.rmdir(self.dir)

    def run_take(self, fake, stop_timeout=1.0, record=0.3):
        take = ls.Take(self.wav, ["Supabase", "MCP"], ["uk-UA", "en-US"], "models/x", lambda: fake, stop_timeout).begin()
        time.sleep(record)
        return take, take.stop()

    def test_finals_after_activity_end(self):
        fake = FakeWS(setup_delay=0.15, after_end=[FINAL, DONE], interim="Перенеси дзвінок")
        take, r = self.run_take(fake)
        self.assertIsNone(r["error"])
        self.assertEqual(r["text"], "Перенеси дзвінок з Тарасом на 27 жовтня.")
        self.assertEqual(r["language"], "uk")
        self.assertIsNotNone(r["afterEndMs"]); self.assertIsNotNone(r["setupMs"])
        self.assertGreater(r["interim"], 0)
        # setup, activityStart, the audio in order and nothing before activityStart, activityEnd
        setup = fake.sent[0]["setup"]
        self.assertTrue(setup["realtimeInputConfig"]["automaticActivityDetection"]["disabled"])
        self.assertEqual(setup["inputAudioTranscription"],
                         {"languageCodes": ["uk-UA", "en-US"], "customVocabulary": ["Supabase", "MCP"]})
        self.assertEqual(fake.sent[1], {"realtimeInput": {"activityStart": {}}})
        self.assertEqual(fake.sent[-1], {"realtimeInput": {"activityEnd": {}}})
        audio = [s["realtimeInput"]["audio"] for s in fake.sent[2:-1]]
        self.assertTrue(all(a["mimeType"] == "audio/pcm;rate=16000" for a in audio))
        chunks = [base64.b64decode(a["data"]) for a in audio]
        self.assertTrue(all(len(c) <= 3200 for c in chunks))
        self.assertEqual(b"".join(chunks), self.pcm)
        self.assertTrue(fake.closed_by_us)

    def test_audio_before_setup_is_queued(self):
        fake = FakeWS(setup_delay=0.5, after_end=[FINAL, DONE])
        take, r = self.run_take(fake, record=0.2)   # released before Google answered the setup
        self.assertIsNone(r["error"])
        self.assertEqual(fake.sent[1], {"realtimeInput": {"activityStart": {}}})
        chunks = [base64.b64decode(s["realtimeInput"]["audio"]["data"]) for s in fake.sent[2:-1]]
        self.assertEqual(b"".join(chunks), self.pcm)

    def test_no_finals_is_an_error(self):
        fake = FakeWS(after_end=[DONE])
        take, r = self.run_take(fake)
        self.assertIsNone(r["text"])
        self.assertEqual(r["error"], "empty transcript")

    def test_silent_server_times_out(self):
        fake = FakeWS(after_end=[])
        t0 = time.time()
        take, r = self.run_take(fake, stop_timeout=0.3)
        self.assertIsNone(r["text"])
        self.assertTrue(r["error"].startswith("timeout"), r["error"])
        self.assertLess(time.time() - t0, 0.3 + ls.DRAIN_MAX + 0.5)

    def test_close_before_the_answer_is_an_error(self):
        fake = FakeWS(after_end=[("close", 1011, "Internal error")])
        take, r = self.run_take(fake)
        self.assertIsNone(r["text"])
        self.assertEqual(r["error"], "close 1011: Internal error")

    def test_go_away_is_an_error(self):
        fake = FakeWS(after_end=[msg({"goAway": {"timeLeft": "1s"}}), FINAL, DONE])
        take, r = self.run_take(fake)
        self.assertIsNone(r["text"])
        self.assertTrue(r["error"].startswith("goAway"), r["error"])

    def test_partial_while_speaking(self):
        fake = FakeWS(after_end=[FINAL, DONE], interim="Перенеси дзвінок")
        take = ls.Take(self.wav, [], ["uk-UA"], "models/x", lambda: fake, 1.0).begin()
        time.sleep(0.3)
        self.assertEqual(take.partial(), "Перенеси дзвінок")
        take.stop()
        self.assertEqual(take.partial(), "Перенеси дзвінок з Тарасом на 27 жовтня.")

    def test_cancel(self):
        fake = FakeWS(after_end=[FINAL, DONE])
        take = ls.Take(self.wav, [], ["uk-UA"], "models/x", lambda: fake, 1.0).begin()
        time.sleep(0.2)
        take.cancel()
        self.assertTrue(take.done.wait(1))
        self.assertTrue(fake.closed_by_us)
        self.assertEqual(take.result()["error"], "cancelled")


class RefusingWS(FakeWS):
    """Google refusing the key: a close instead of setupComplete, or after `after` s of audio."""

    def __init__(self, code=1007, reason="API key not valid. Please pass a valid API key.", after=None):
        super().__init__()
        self.code, self.reason, self.after = code, reason, after

    def send(self, obj):
        self.sent.append(obj)
        if "setup" in obj:
            if self.after is None:
                self._later(0.02, ("close", self.code, self.reason))
            else:
                self._later(0.0, ("msg", json.dumps({"setupComplete": {}}).encode()))
                self._later(self.after, ("close", self.code, self.reason))


class TwoKeys(unittest.TestCase):
    setUp, tearDown = StopSequence.setUp, StopSequence.tearDown

    def run_keys(self, free, paid, record=0.3):
        refusals = []
        take = ls.Take(self.wav, [], ["uk-UA"], "models/x", [("free", lambda: free), ("paid", lambda: paid)], 1.0,
                       on_refused=lambda label, why: refusals.append((label, why))).begin()
        time.sleep(record)
        return take.stop(), refusals

    def audio(self, fake):
        return b"".join(base64.b64decode(s["realtimeInput"]["audio"]["data"])
                        for s in fake.sent if "audio" in s.get("realtimeInput", {}))

    def test_free_key_serves_when_accepted(self):
        free, paid = FakeWS(after_end=[FINAL, DONE]), FakeWS(after_end=[FINAL, DONE])
        r, refusals = self.run_keys(free, paid)
        self.assertIsNone(r["error"])
        self.assertEqual((r["key"], r["keySwitch"]), ("free", None))
        self.assertEqual(paid.sent, [])
        self.assertEqual(refusals, [])

    def test_invalid_free_key_falls_back_to_paid(self):
        free, paid = RefusingWS(), FakeWS(after_end=[FINAL, DONE])
        r, refusals = self.run_keys(free, paid)
        self.assertIsNone(r["error"])
        self.assertEqual(r["text"], "Перенеси дзвінок з Тарасом на 27 жовтня.")
        self.assertEqual(r["key"], "paid")
        self.assertEqual(r["keySwitch"], "free refused: close 1007: API key not valid. Please pass a valid API key.")
        self.assertEqual(refusals[0][0], "free")
        self.assertEqual(self.audio(paid), self.pcm)

    def test_quota_mid_take_resends_the_whole_take(self):
        free = RefusingWS(1011, "You exceeded your current quota, please check your plan and billing details.", after=0.15)
        paid = FakeWS(after_end=[FINAL, DONE])
        r, refusals = self.run_keys(free, paid)
        self.assertIsNone(r["error"])
        self.assertEqual(r["key"], "paid")
        self.assertGreater(len(self.audio(free)), 0)
        self.assertEqual(self.audio(paid), self.pcm)   # nothing lost, nothing doubled

    def test_handshake_429_falls_back(self):
        def free():
            raise ls.RateLimited("handshake HTTP/1.1 429 Too Many Requests: RESOURCE_EXHAUSTED")
        paid = FakeWS(after_end=[FINAL, DONE])
        take = ls.Take(self.wav, [], ["uk-UA"], "models/x", [("free", free), ("paid", lambda: paid)], 1.0).begin()
        time.sleep(0.3)
        r = take.stop()
        self.assertIsNone(r["error"])
        self.assertEqual(r["key"], "paid")
        self.assertTrue(r["keySwitch"].startswith("free refused: RateLimited"), r["keySwitch"])

    def test_internal_error_is_not_a_refusal(self):
        free, paid = RefusingWS(1011, "Internal error encountered.", after=0.1), FakeWS(after_end=[FINAL, DONE])
        r, refusals = self.run_keys(free, paid)
        self.assertEqual(r["error"], "close 1011: Internal error encountered.")
        self.assertEqual((r["key"], refusals, paid.sent), ("free", [], []))

    def test_paid_refused_too_is_an_error(self):
        r, refusals = self.run_keys(RefusingWS(), RefusingWS())
        self.assertIsNone(r["text"])
        self.assertEqual(r["key"], "paid")
        self.assertTrue(r["error"].startswith("close 1007"), r["error"])


class KeyOrder(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.paid, self.free = os.path.join(self.dir, "gemini-key"), os.path.join(self.dir, "gemini-key-free")
        with open(self.paid, "w") as f:
            f.write("PAID\n")
        self.live = ls.Live("models/x", ["uk-UA"], 1.0, self.paid, os.path.join(self.dir, "live.log"),
                            free_key_file=self.free)

    def tearDown(self):
        for name in os.listdir(self.dir):
            os.remove(os.path.join(self.dir, name))
        os.rmdir(self.dir)

    def test_no_free_key_is_paid_only(self):
        self.assertEqual(self.live.keys(), [("paid", "PAID")])

    def test_free_first_until_refused_then_back_after_reset_or_new_key(self):
        with open(self.free, "w") as f:
            f.write("FREE")
        self.assertEqual(self.live.keys(), [("free", "FREE"), ("paid", "PAID")])
        self.live.refused("FREE", "close 1011: quota")
        self.assertEqual(self.live.keys(), [("paid", "PAID")])
        with open(self.live.log_file) as f:
            self.assertIn("free key refused (close 1011: quota); paid key until", f.read())
        self.live.free_refused = ("FREE", time.time() - 1)   # past the quota reset
        self.assertEqual(self.live.keys()[0], ("free", "FREE"))
        self.live.refused("FREE", "quota")
        with open(self.free, "w") as f:
            f.write("FREE2")                                 # a new free key is tried at once
        self.assertEqual(self.live.keys()[0], ("free", "FREE2"))

    def test_quota_reset_is_midnight_pacific(self):
        at = ls.datetime(2026, 10, 27, 23, 30, tzinfo=ls.PACIFIC).timestamp()
        self.assertEqual(ls.next_quota_reset(at), ls.datetime(2026, 10, 28, 0, 0, tzinfo=ls.PACIFIC).timestamp())
        at = ls.datetime(2026, 10, 28, 0, 0, 1, tzinfo=ls.PACIFIC).timestamp()
        self.assertEqual(ls.next_quota_reset(at), ls.datetime(2026, 10, 29, 0, 0, tzinfo=ls.PACIFIC).timestamp())


if __name__ == "__main__":
    unittest.main(verbosity=2)
