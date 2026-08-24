import re, glob, os

CJK = re.compile(r'[\u4e00-\u9fff]')

LOCL = {'localize','MPLocalized','AKLocalizedString','NSLocalizedString','localizedStringForKey',
        'Localized','AKLocalized','localized','localizeWith','L'}

def blank_comments(raw):
    out = list(raw); i = 0; n = len(raw); mode = 0; instr = False
    while i < n:
        c = raw[i]; nx = raw[i + 1] if i + 1 < n else ''
        if mode == 2:
            if c == '*' and nx == '/': out[i] = out[i + 1] = ' '; i += 2; mode = 0; continue
            out[i] = c if c == '\n' else ' '; i += 1; continue
        if mode == 1:
            if c == '\n': mode = 0; out[i] = '\n'
            else: out[i] = ' '
            i += 1; continue
        if instr:
            if c == '\\': i += 2; continue
            if c == '"': instr = False
            i += 1; continue
        if c == '"': instr = True; i += 1; continue
        if c == '/' and nx == '/': mode = 1; i += 2; continue
        if c == '/' and nx == '*': mode = 2; i += 2; continue
        i += 1
    return ''.join(out)

def is_comment_arg(blank, start):
    # blank is comment-blanked source. Determine if literal at `start` (opening @ or ") is a
    # non-first argument of a localize-type call.
    # walk back: find the ',' that precedes start (skipping ws)
    j = start - 1
    while j >= 0 and blank[j] in ' \t\n': j -= 1
    if j < 0 or blank[j] != ',': return False
    # backtrack to the matching '(' of the call that owns this argument list
    bal = 0; p = start - 1
    while p >= 0:
        ch = blank[p]
        if ch == ')': bal += 1
        elif ch == '(':
            if bal == 0: break
            bal -= 1
        p -= 1
    if p < 0: return False
    q = p - 1
    while q >= 0 and (blank[q].isalnum() or blank[q] == '_' or blank[q] == '.'):
        q -= 1
    ident = blank[q + 1:p]
    return (ident in LOCL) or ident.split('.')[-1] in LOCL if '.' in ident else (ident in LOCL)

# Signals meaning the literal is used for logic / as identifier, NOT displayed
LOGIC_RE = [
    r'isEqualToString\s*:', r'isEqual\s*:\s*$', r'compare\s*:\s*$',
    r'objectForKey\s*:', r'valueForKey\s*:', r'setValue:[^,]+forKey\s*:',
    r'forKey\s*:\s*$', r'registerClass\s*:\s*$',
    r'dequeueReusableCellWithIdentifier\s*:\s*$', r'reuseIdentifier\s*:\s*$',
    r'identifier\b', r'cellIdentifier\b',
    r'[@\[]?@"\w+"\s*:\s*@?["{]',  # @"x":  dictionary key
    r'key\s*:\s*$', r'Key\s*:\s*$', r'prefKey\s*:\s*$', r'key\s*=\s*$',
    r'getPref\w*\s*\(\s*$', r'setPref\w*\s*\([^)]*,\s*$',
    r'NotificationName\s*[:=]\s*$', r'name\s*:\s*$', r'type\s*:\s*$',
    r'status\s*:\s*$', r'value\s*:\s*$', r'filter\s*:\s*$',
    r'selectedFilter\s*[:=]\s*$', r'\.tag\s*:\s*$', r'tag\s*:\s*$',
    r'userInfo\s*[@\[]\s*$',
    r'placeholder\s*:\s*$',  # placeholder is display, not logic; keep separate
]
# String literals that are almost certainly logic sentinels (even if they look like labels)
SENTINEL = {
    '全部','正式版','测试版','成功','失败','已开启','已关闭','开启','关闭','名称','游戏版本',
    '取消','好的','确定','确定清除','保存','重试','查看详情',
}

def is_logic(prev, content):
    for w in LOGIC_RE:
        if re.search(w, prev, re.X):
            return True
    # dictionary key: after @"..." colons appear ( @"key":  or  @"key": "val")
    return False

def scan(path):
    raw = open(path, encoding='utf-8').read()
    blank = blank_comments(raw)
    n = len(raw); i = 0; res = []
    while i < n:
        if blank.startswith('@"', i):
            j = i + 2
            while j < n:
                if blank[j] == '\\': j += 2; continue
                if blank[j] == '"': break
                j += 1
            if j < n:
                content = raw[i + 2:j]
                end = j + 1
                if CJK.search(content):
                    if not is_comment_arg(blank, i):
                        res.append((raw.count('\n', 0, i) + 1, content, i, end))
                i = end + 1
                continue
        i += 1
    return raw, res

def main():
    files = glob.glob('Natives/**/*.m', recursive=True)
    total = 0
    for f in sorted(files):
        raw, res = scan(f)
        if not res: continue
        disp = []
        for ln, content, pos, end in res:
            prev = raw[max(0, pos - 100):pos].rstrip(' \t\n~;')
            # exclude logic identifiers
            if is_logic(prev, content):
                continue
            disp.append((ln, content))
        if disp:
            total += len(disp)
            print('### %s (%d)' % (f, len(disp)))
            for ln, content in disp:
                print('   L%d %s' % (ln, content.replace('\n','\\n')[:110]))
    print('\nTOTAL DISPLAY (after logic/comment filter):', total)

if __name__ == '__main__':
    main()