#!/usr/bin/env python3
"""How many binaries a file-signature check finds that the NUL probe misses, and the reverse.

usage: magic_survey.py ZGREP DIR   (aggregates only: counts and extensions)
"""
import os,sys,subprocess,collections
zg,base=sys.argv[1],sys.argv[2]
MAGIC=[(b'%PDF-','pdf'),(b'\x7fELF','elf'),(b'\x89PNG\r\n\x1a\n','png'),(b'\xff\xd8\xff','jpeg'),(b'GIF8','gif'),
 (b'PK\x03\x04','zip'),(b'\x1f\x8b','gzip'),(b'BZh','bzip2'),(b'\xfd7zXZ\x00','xz'),(b'(\xb5/\xfd','zstd'),(b"7z\xbc\xaf'\x1c",'7z'),
 (b'GGUF','gguf'),(b'SQLite format 3\x00','sqlite'),(b'\x00asm','wasm'),(b'MZ','pe'),(b'\xca\xfe\xba\xbe','macho/class'),
 (b'\xcf\xfa\xed\xfe','macho'),(b'RIFF','riff'),(b'OggS','ogg'),(b'fLaC','flac'),(b'ID3','mp3'),(b'\x1aE\xdf\xa3','mkv'),
 (b'wOFF','woff'),(b'wOF2','woff2'),(b'\x00\x01\x00\x00','ttf'),(b'OTTO','otf'),(b'!<arch>\n','ar'),(b'\x93NUMPY','npy'),
 (b'PAR1','parquet'),(b'ARROW1','arrow'),(b'\x89HDF','hdf5')]
def kind(h):
    for m,n in MAGIC:
        if h.startswith(m): return n
    if len(h)>=12 and h[4:8]==b'ftyp': return 'mp4'
    return None
# all files zg would consider (no binary filter: -a), respecting ignore rules
p=subprocess.run([zg,"-a","-l","-e","",base],capture_output=True,text=True,errors="replace")
files=[l for l in p.stdout.splitlines() if l]
stats=collections.Counter(); by=collections.Counter(); missed=collections.Counter()
for f in files:
    try:
        with open(f,'rb') as fh: head=fh.read(8192)
    except Exception: continue
    k=kind(head); nul=b'\0' in head
    stats[(k is not None, nul)]+=1
    if k and not nul: by[k]+=1
    if nul and not k: missed[os.path.splitext(f)[1] or '(none)']+=1
print("files:",len(files))
print("magic+NUL(8K):",stats[(True,True)]," magic only (NEW catch):",stats[(True,False)]," NUL only (magic misses):",stats[(False,True)]," neither:",stats[(False,False)])
print("new catches by format:",by.most_common(10))
print("binaries magic would miss, by ext:",missed.most_common(12))
