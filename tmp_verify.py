# -*- coding: utf-8 -*-
import subprocess, re

# Collect all localize keys introduced in the diff (hooks are simple)
diff = subprocess.check_output(['git','diff','-U0'], cwd='/workspace', text=True)
newkeys=set()
for m in re.finditer(r'localize\(@"([^"]+)"', diff):
    newkeys.add(m.group(1))

def keyset(path):
    s=set()
    for line in open(path, encoding='utf-8'):
        m=re.match(r'"([^"]+)"\s*=', line)
        if m: s.add(m.group(1))
    return s

en=keyset('Natives/resources/en.lproj/Localizable.strings')
zh=keyset('Natives/resources/zh-Hans.lproj/Localizable.strings')
print('new localize keys in diff:', len(newkeys))
missing=[]
for k in sorted(newkeys):
    if k not in en or k not in zh:
        missing.append(k)
print('MISSING in en/zh:', missing if missing else 'none')

# also check duplicates in strings files
import collections
for p in ['Natives/resources/en.lproj/Localizable.strings','Natives/resources/zh-Hans.lproj/Localizable.strings']:
    c=collections.Counter(re.findall(r'^"(.*?)" =', open(p,encoding='utf-8').read(), re.M))
    dup=[k for k,v in c.items() if v>1]
    print(p, 'dups:', dup if dup else 'none', 'lines:', sum(1 for _ in open(p,encoding='utf-8')))