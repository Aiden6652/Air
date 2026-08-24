# -*- coding: utf-8 -*-
en_add = {
 'i18n_str_2016':'Shader Management',
 'i18n_str_2017':'Frosted Glass',
 'i18n_str_2018':'Half Width',
 'i18n_str_2019':'Compact',
 'i18n_str_2020':'Switch to Full Width',
 'i18n_str_2021':'Hide this Tile',
 'i18n_str_2022':'Purple',
 'i18n_str_2023':'Red',
 'i18n_str_2024':'Pink',
 'i18n_str_2025':'Indigo',
 'i18n_str_2026':'Isolated',
 'i18n_str_2027':'New Version',
 'i18n_str_2028':'Go to Downloads',
 'i18n_str_2029':'Currently using this directory',
 'i18n_str_2030':'Delete (switch to another directory first)',
 'i18n_str_2031':'Game Version',
 'i18n_str_2032':'All Versions',
 'i18n_str_2033':'Recently Updated',
 'i18n_str_2034':'No matching version',
 'i18n_str_2035':'Popularity',
 'i18n_str_2036':'Java Version',
 'i18n_str_2037':'Memory Allocation',
 'i18n_str_2038':'Clear JVM Arguments',
 'i18n_str_2039':'Mod Management',
 'i18n_str_2040':'Resource Pack Management',
 'i18n_str_2041':'Data Pack Management',
 'i18n_str_2042':'World Management',
 'i18n_str_2043':'Tap to Install',
 'i18n_str_2044':'Tap to Clear',
 'i18n_str_2045':'Waiting for players…',
 'i18n_str_2046':'Creating room…',
 'i18n_str_2047':'Host is Ready',
 'i18n_str_2048':'Additional Options',
 'i18n_str_2049':'Please restart the launcher and try again.',
 'i18n_str_2050':'LittleSkin Login',
 'i18n_str_2051':'Collapse',
 'i18n_str_2052':'Preparing...',
 'i18n_str_2053':'[✓] Current status: ON',
 'i18n_str_2054':'Enabling JIT via TrollStore...',
 'i18n_str_2055':'Select a modpack file',
 'i18n_str_2056':'   Author: %@',
 'i18n_str_2057':'Graphics API',
 'i18n_str_2058':'Release',
 'i18n_str_2059':'Snapshot',
 'i18n_str_2060':'Copy',
 'i18n_str_2061':'Downloads',
 'i18n_str_2062':'Blue',
 'i18n_str_2063':'Cyan',
 'i18n_str_2064':'Latest Release',
 'i18n_str_2065':'Green',
 'i18n_str_2066':'Yellow',
 'i18n_str_2067':'Orange',
}

zh_add = {
 'i18n_str_2016':'光影管理',
 'i18n_str_2017':'毛玻璃',
 'i18n_str_2018':'半宽',
 'i18n_str_2019':'紧凑',
 'i18n_str_2020':'切换为全宽',
 'i18n_str_2021':'隐藏此磁贴',
 'i18n_str_2022':'紫色',
 'i18n_str_2023':'红色',
 'i18n_str_2024':'粉色',
 'i18n_str_2025':'靛蓝',
 'i18n_str_2026':'隔离',
 'i18n_str_2027':'新建版本',
 'i18n_str_2028':'去下载版本',
 'i18n_str_2029':'当前正在使用此目录',
 'i18n_str_2030':'删除（需先切换到其他目录）',
 'i18n_str_2031':'游戏版本',
 'i18n_str_2032':'全部版本',
 'i18n_str_2033':'最近更新',
 'i18n_str_2034':'未匹配到版本',
 'i18n_str_2035':'关注度',
 'i18n_str_2036':'Java版本',
 'i18n_str_2037':'内存分配',
 'i18n_str_2038':'清除JVM参数',
 'i18n_str_2039':'模组管理',
 'i18n_str_2040':'资源包管理',
 'i18n_str_2041':'数据包管理',
 'i18n_str_2042':'世界管理',
 'i18n_str_2043':'点击安装',
 'i18n_str_2044':'点击清除',
 'i18n_str_2045':'等待玩家加入…',
 'i18n_str_2046':'创建房间中…',
 'i18n_str_2047':'房主已就绪',
 'i18n_str_2048':'附加选项',
 'i18n_str_2049':'请重启启动器后重试。',
 'i18n_str_2050':'LittleSkin 登录',
 'i18n_str_2051':'收起',
 'i18n_str_2052':'正在准备...',
 'i18n_str_2053':'[✓] 当前状态: 已开启 (ON)',
 'i18n_str_2054':'正在通过 TrollStore 启用 JIT...',
 'i18n_str_2055':'选择整合包文件',
 'i18n_str_2056':'   作者: %@',
 'i18n_str_2057':'图形 API',
 'i18n_str_2058':'正式版',
 'i18n_str_2059':'测试版',
 'i18n_str_2060':'复制',
 'i18n_str_2061':'下载数',
 'i18n_str_2062':'蓝色',
 'i18n_str_2063':'青色',
 'i18n_str_2064':'最新发布',
 'i18n_str_2065':'绿色',
 'i18n_str_2066':'黄色',
 'i18n_str_2067':'橙色',
}

def esc(v):
    return v # no quotes/backslashes in values

base = 'Natives/resources/'
for lang, add in (('en.lproj', en_add), ('zh-Hans.lproj', zh_add)):
    path = base + lang + '/Localizable.strings'
    with open(path, encoding='utf-8') as f:
        txt = f.read()
    if not txt.endswith('\n'):
        txt += '\n'
    lines = []
    for k in sorted(add):
        v = esc(add[k])
        lines.append('"%s" = "%s";' % (k, v))
    block = '\n\n' + '\n'.join(lines) + '\n'
    # avoid duplicates
    missing = [k for k in add if ('"%s"' % k) not in txt]
    if missing:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(txt + block)
        print('%s appended %d keys' % (lang, len(add)))
    else:
        print('%s already present, skipped' % lang)