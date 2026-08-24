# -*- coding: utf-8 -*-
import subprocess, os

def strip_code(raw):
    out=[];i=0;n=len(raw);mode='code';instr=False
    while i<n:
        c=raw[i];nx=raw[i+1] if i+1<n else ''
        if mode=='block':
            if c=='*' and nx=='/': mode='code';i+=2;continue
            i+=1;continue
        if mode=='line':
            if c=='\n': mode='code'
            i+=1;continue
        if instr:
            if c=='\\': i+=2;continue
            if c=='"': instr=False
            i+=1;continue
        if c=='"': instr=True; i+=1;continue
        if c=='/' and nx=='/': mode='line';i+=2;continue
        if c=='/' and nx=='*': mode='block';i+=2;continue
        if c=="'":
            # char literal: skip to closing ' handling escapes
            i+=1
            while i<n:
                if raw[i]=='\\': i+=2;continue
                if raw[i]=="'": i+=1;break
                i+=1
            continue
        out.append(c);i+=1
    return ''.join(out)

def result(code):
    st=[]
    pairs={'(':')','[':']','{':'}'};close={v:k for k,v in pairs.items()}
    for c in code:
        if c in pairs: st.append(c)
        elif c in close:
            if not st or st[-1]!=close[c]:
                return ('mismatch', c)
            st.pop()
    return ('unclosed', st)

touched = subprocess.check_output(['git','status','--short'], cwd='/workspace', text=True)
files=[]
for line in touched.splitlines():
    p=line[3:].strip()
    if p.endswith('.m'): files.append(p)
any_diff=False
for p in sorted(files):
    orig = subprocess.check_output(['git','show','HEAD:'+p], cwd='/workspace', text=True)
    new  = open('/workspace/'+p, encoding='utf-8').read()
    ro, rn = result(strip_code(orig)), result(strip_code(new))
    flag='' if ro==rn else '  <<< NEW IMBALANCE INTRODUCED'
    if ro!=rn: any_diff=True
    print('%-45s HEAD=%-14s new=%s%s' % (p, ro, rn, flag))
print('DONE any_new_imbalance=%s' % any_diff)