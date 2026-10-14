import tempfile,unittest,zlib,struct
from pathlib import Path
class FixtureTests(unittest.TestCase):
    def test_generator_writes_valid_small_chunks(self):
        from tests.security.png_fixture import write_metadata_png
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'fixture.png'
            result=write_metadata_png(p,4096,1024)
            self.assertEqual(result['expandedBytes'],4096)
            data=p.read_bytes();self.assertEqual(data[:8],b'\x89PNG\r\n\x1a\n')
            pos=8;expanded=0;keys=[]
            while pos<len(data):
                size=struct.unpack('>I',data[pos:pos+4])[0];kind=data[pos+4:pos+8];body=data[pos+8:pos+8+size]
                crc=struct.unpack('>I',data[pos+8+size:pos+12+size])[0]
                self.assertEqual(crc,zlib.crc32(kind+body)&0xffffffff)
                if kind==b'zTXt':
                    key,compressed=body.split(b'\0',1);keys.append(key)
                    expanded+=len(zlib.decompress(compressed[1:]))
                pos+=12+size
            self.assertEqual(expanded,4096);self.assertEqual(len(set(keys)),4)
            with self.assertRaises(ValueError):write_metadata_png(p,2*1024**3,1024)
