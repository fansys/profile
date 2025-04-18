function FindProxyForURL(url, host) {
    // JetBrains 插件商店相关域名
    var proxyDomains = [
        "plugins.jetbrains.com",
        "downloads.marketplace.jetbrains.com",
        "download.jetbrains.com",
        "download-cdn.jetbrains.com",
        "google.com",
        "dl.google.com",
        "www.google.com"
    ];
    
    for (var i = 0; i < proxyDomains.length; i++) {
        if (dnsDomainIs(host, proxyDomains[i])) {
            return "PROXY 127.0.0.1:7890"; // 请替换为你的代理地址和端口
        }
    }
    
    return "DIRECT"; // 其他流量直连
}
