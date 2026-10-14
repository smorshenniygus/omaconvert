"""Bounded fixture writer; never decode a large fixture outside verified limits."""
import hashlib
import os
from pathlib import Path
import struct
import zlib


def write_metadata_png(path: Path, expanded_bytes: int, chunk_bytes: int) -> dict:
    if not (0 < expanded_bytes <= 1024**3 and 0 < chunk_bytes <= 4*1024**2):
        raise ValueError('Fixture exceeds its generation budget')
    if (expanded_bytes + chunk_bytes - 1)//chunk_bytes > 4096:
        raise ValueError('Too many metadata chunks')
    def chunk(handle, kind, body):
        handle.write(struct.pack('>I',len(body))+kind+body+struct.pack('>I',zlib.crc32(kind+body)&0xffffffff))
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'wb') as handle:
        handle.write(b'\x89PNG\r\n\x1a\n')
        chunk(handle,b'IHDR',struct.pack('>IIBBBBB',1,1,8,2,0,0,0))
        left=expanded_bytes;index=0
        while left:
            size=min(left,chunk_bytes)
            chunk(handle,b'zTXt',f'metadata-{index}'.encode()+b'\0\0'+zlib.compress(b'x'*size))
            left-=size;index+=1
        chunk(handle,b'IDAT',zlib.compress(b'\0\xff\0\0'))
        chunk(handle,b'IEND',b'')
    with path.open('rb') as source:
        digest=hashlib.file_digest(source,'sha256').hexdigest()
    return {'expandedBytes':expanded_bytes,'compressedBytes':path.stat().st_size,'sha256':digest}
