import io,json,unittest
from lib.events import EventSink
class EventLimits(unittest.TestCase):
    def test_oversized_event_rejected_before_write(self):
        from lib.streams import OutputLimitExceeded
        stream=io.StringIO()
        with self.assertRaises(OutputLimitExceeded): EventSink(stream).emit('probe',value='x'*65536)
        self.assertEqual(stream.getvalue(),'')
    def test_large_batch_paths_are_chunked_in_order(self):
        stream=io.StringIO();paths=['/tmp/'+str(i)+'я'*500 for i in range(200)]
        EventSink(stream).emit('batch-complete',paths=paths,path=paths[0],done=200)
        lines=stream.getvalue().splitlines(keepends=True)
        self.assertTrue(all(len(x.encode())<=65536 for x in lines))
        events=[json.loads(x) for x in lines]
        self.assertTrue(events[-1]['resultsChunked'])
        actual=[p for e in events[:-1] for p in e['paths']]
        self.assertEqual(actual,paths)
