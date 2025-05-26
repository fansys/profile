function FindProxyForURL(url, host) {
    // JetBrains 插件商店相关域名
    var proxyDomains = [
        "jetbrains.com",
        "*.jetbrains.com",
        "google.com",
        "*.google.com",
        "gradle.org",
        "*.gradle.org"
    ];
    
    for (var i = 0; i < proxyDomains.length; i++) {
        if (shExpMatch(host, proxyDomains[i])) {
            return "PROXY 127.0.0.1:7890"; // 请替换为你的代理地址和端口
        }
    }
    
    return "DIRECT"; // 其他流量直连
}
