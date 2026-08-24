import re, glob, io, sys

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
    j = start - 1
    while j >= 0 and blank[j] in ' \t\n': j -= 1
    if j < 0 or blank[j] != ',': return False
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

LOGIC_RE = [
    r'isEqualToString\s*:', r'isEqual\s*:\s*$', r'compare\s*:\s*$',
    r'objectForKey\s*:', r'valueForKey\s*:', r'setValue:[^,]+forKey\s*:',
    r'forKey\s*:\s*$', r'registerClass\s*:\s*$',
    r'dequeueReusableCellWithIdentifier\s*:\s*$', r'reuseIdentifier\s*:\s*$',
    r'identifier\b', r'cellIdentifier\b',
    r'[@\[]?@"\w+"\s*:\s*@?["{]',
    r'key\s*:\s*$', r'Key\s*:\s*$', r'prefKey\s*:\s*$', r'key\s*=\s*$',
    r'getPref\w*\s*\(\s*$', r'setPref\w*\s*\([^)]*,\s*$',
    r'NotificationName\s*[:=]\s*$', r'name\s*:\s*$', r'type\s*:\s*$',
    r'status\s*:\s*$', r'value\s*:\s*$', r'filter\s*:\s*$',
    r'selectedFilter\s*[:=]\s*$', r'\.tag\s*:\s*$', r'tag\s*:\s*$',
    r'userInfo\s*[@\[]\s*$',
]

def is_logic(prev, content):
    for w in LOGIC_RE:
        if re.search(w, prev, re.X):
            return True
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
                if CJK.search(content) and not is_comment_arg(blank, i):
                    prev = raw[max(0, i - 100):i].rstrip(' \t\n~;')
                    if not is_logic(prev, content):
                        res.append((raw.count('\n', 0, i) + 1, content, i, end))
                i = end + 1
                continue
        i += 1
    return res

# core content -> key
PLAIN = {
 '收起':'i18n_str_2051','相关性':'i18n_str_162','全部':'resman.mods.filter.all',
 '毛玻璃':'i18n_str_2017','取消':'resman.common.cancel','正式版':'i18n_str_2058',
 '测试版':'i18n_str_2059','游戏版本':'i18n_str_2031','全部版本':'i18n_str_2032',
 '最近更新':'i18n_str_2033','未匹配到版本':'i18n_str_2034','关注度':'i18n_str_2035',
 '半宽':'i18n_str_2018','紧凑':'i18n_str_2019','切换为全宽':'i18n_str_2020',
 '隐藏此磁贴':'i18n_str_2021','紫色':'i18n_str_2022','红色':'i18n_str_2023',
 '粉色':'i18n_str_2024','靛蓝':'i18n_str_2025','光影管理':'i18n_str_2016',
 '隔离':'i18n_str_2026','正在准备...':'i18n_str_2052','新建版本':'i18n_str_2027',
 '去下载版本':'i18n_str_2028','当前正在使用此目录':'i18n_str_2029',
 '删除（需先切换到其他目录）':'i18n_str_2030','点击安装':'i18n_str_2043',
 '点击清除':'i18n_str_2044','等待玩家加入…':'i18n_str_2045',
 '创建房间中…':'i18n_str_2046','房主已就绪':'i18n_str_2047',
 '附加选项':'i18n_str_2048','请重启启动器后重试。':'i18n_str_2049',
 'LittleSkin 登录':'i18n_str_2050','选择整合包文件':'i18n_str_2055',
 '正在通过 TrollStore 启用 JIT...':'i18n_str_2054',
 '[✓] 当前状态: 已开启 (ON)':'i18n_str_2053',
 '下载数':'i18n_str_2061',
 '蓝色':'i18n_str_2062',
 '青色':'i18n_str_2063',
 '最新发布':'i18n_str_2064',
 '绿色':'i18n_str_2065',
 '黄色':'i18n_str_2066',
 '橙色':'i18n_str_2067',
}

# exact content -> full replacement expression (no @"" wrapping; raw token replaced entirely)
SPECIAL = {
 ' 自定义':'[@" " stringByAppendingString:localize(@"preference.title.appicon-custom", nil)]',
 ' 复制':'[@" " stringByAppendingString:localize(@"i18n_str_2060", nil)]',
 ' 隔离 ':'[[@" " stringByAppendingString:localize(@"i18n_str_2026", nil)] stringByAppendingString:@" "]',
 '  · 隔离':'[@"  · " stringByAppendingString:localize(@"i18n_str_2026", nil)]',
 '   作者: %@':'localize(@"i18n_str_2056", nil)',
}

def quote(s):
    return '@"' + s + '"'

def repl_expr(content):
    if content in SPECIAL:
        return SPECIAL[content]
    core = content.lstrip()
    lead = content[:len(content) - len(core)]
    if core in PLAIN:
        key = PLAIN[core]
        if lead:
            return '[' + quote(lead) + ' stringByAppendingString:localize(' + quote(key) + ', nil)]'
        return 'localize(' + quote(key) + ', nil)'
    return None

# ProfileSettings logic-title arrays: keep Chinese (used as logic keys), localize only at display
TITLES = {'渲染器','图形API','Java版本','内存分配','JVM启动参数','清除JVM参数','名称','游戏版本',
          '游戏目录','模组管理','光影管理','资源包管理','数据包管理','世界管理'}

def main():
    files = glob.glob('Natives/**/*.m', recursive=True)
    total_done = 0; total_skip = 0; total_unmapped = 0
    for f in sorted(files):
        res = scan(f)
        if not res: continue
        raw = open(f, encoding='utf-8').read()
        orig = raw
        # process from end to start so positions remain valid
        for ln, content, pos, end in sorted(res, key=lambda x: -x[2]):
            in_profile = '/ProfileSettingsViewController.m' in f
            core_nows = content.replace(' ', '')
            if in_profile and core_nows in TITLES:
                total_skip += 1
                print('SKIP(logic) %s L%d %r' % (f, ln, content))
                continue
            expr = repl_expr(content)
            if expr is None:
                total_unmapped += 1
                print('UNMAPPED %s L%d %r' % (f, ln, content))
                continue
            raw = raw[:pos] + expr + raw[end:]
            total_done += 1
        if raw != orig:
            open(f, 'w', encoding='utf-8').write(raw)
            print('WROTE %s' % f)
    print('done mapped=%d skipped(logic)=%d unmapped=%d' % (total_done, total_skip, total_unmapped))

if __name__ == '__main__':
    main()