# Cross-platform constants. Dot-sourced.

$SingboxRepo    = 'shtorm-7/sing-box-extended'

$GeoipUrl   = 'https://raw.githubusercontent.com/runetfreedom/russia-blocked-geoip/release/geoip.dat'
$GeositeUrl = 'https://raw.githubusercontent.com/runetfreedom/russia-blocked-geosite/release/geosite.dat'

$DirectTestUrl  = 'https://checkip.amazonaws.com'
$ProxyItTestUrl = 'https://api.ipify.org'
$ProxyIpv6ItNovncTag = 'proxy_ipv6_it_novnc'
$ProxyRuTestUrl = 'https://ident.me'
$AllTestUrls    = @($DirectTestUrl, $ProxyItTestUrl, $ProxyRuTestUrl)

# Non-.ru domain inside geosite-ru-available-only-inside; echoes caller IP.
$RuInsideProbeUrl = 'https://showip.net/'
