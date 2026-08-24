# -*- coding: utf-8 -*-
import re, glob, sys

def strip_code(raw):
    out = [] ; i = 0; n = len(raw); mode='code'; instr=False
    while i < n:
        c = raw[i]; nx = raw[i+1] if i+1<n else ''
        if mode=='block':
            if c=='*' and nx=='/': mode='code'; i+=2; continue
            i+=1; continue
        if mode=='line':
            if c=='\n': mode='code'
            i+=1; continue
        if instr:
            if c=='\\': i+=2; continue
            if c=='"': instr=False
            i+=1; continue
        if c=='"': instr=True; i+=1; continue
        if c=='/' and nx=='/': mode='line'; i+=2; continue
        if c=='/' and nx=='*': mode='block'; i+=2; continue
        if c=="'":  # char literal 'x' or '\xxx'
            if i+2<n: i+=1
            i+=1; continue
        out.append(c); i+=1
    return ''.join(out)

def check(path):
    raw=open(path,encoding='utf-8').read()
    code=strip_code(raw)
    stack=[]
    pairs={'(':')','[':']','{':'}'}
    close={v:k for k,v in pairs.items()}
    for idx,ch in enumerate(code):
        if ch in pairs: stack.append((ch,idx))
        elif ch in close:
            if not stack or stack[-1][0]!=close[ch]:
                print('  MISMATCH %s at offset %d: unexpected %s' % (path, idx, ch)); return False
            stack.pop()
    if stack:
        print('  UNCLOSED %s: %s' % (path, stack[:5])); return False
    return True

files = glob.glob('Natives/**/*.m', recursive=True)
# only files we touched
import subprocess
touched = subprocess.check_output(['git','status','--short'], cwd='/workspace', text=True)
bad=0; checked=0
for line in touched.splitlines():
    p=line[3:].strip()
    if p.endswith('.m') or p.endswith('.h') or 'Localizable.strings' in p:
        if p.endswith('.m'):
            checked+=1
            if not check('/workspace/'+p): bad+=1
print('checked %d .m files, %d with bracket problems' % (checked,bad))