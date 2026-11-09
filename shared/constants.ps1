# Cross-platform constants. Dot-sourced.

$SingboxRepo    = 'shtorm-7/sing-box-extended'

$GeodataRepo = 'runetfreedom/russia-v2ray-rules-dat'

$DirectTestUrl  = 'https://checkip.amazonaws.com'
$ProxyItTestUrl = 'https://api.ipify.org'
$ProxyItHttp3TestUrl = 'https://meduza.io/cdn-cgi/trace'
$ProxyIpv6ItNovncTag = 'proxy_ipv6_it_novnc'
$ProxyRuTestUrl = 'https://ident.me'
$AllTestUrls    = @($DirectTestUrl, $ProxyItTestUrl, $ProxyRuTestUrl)

# Non-.ru domain inside geosite-ru-available-only-inside; echoes caller IP.
$RuInsideProbeUrl = 'https://showip.net/'
