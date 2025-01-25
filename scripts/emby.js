/***
# EmbyPremiere
http-response ^https?:\/\/mb3admin.com\/admin\/service\/registration\/validateDevice requires-body=true, script-path=https://raw.githubusercontent.com/Tartarus2014/Script/master/Emby.js,tag=embyUnlocked

emby.js = type=http-response,pattern=^https?:\/\/mb3admin.com\/admin\/service\/registration\/validateDevice,requires-body=1,max-size=0,script-path=https://raw.githubusercontent.com/Tartarus2014/Script/master/Emby.js


hostname = mb3admin.com
**/
const URL_PATTERNS = {
  validateDevice: '/admin/service/registration/validateDevice',
  appstoreRegister: '/admin/service/appstore/register',
  validate: '/admin/service/registration/validate',
  getStatus: '/admin/service/registration/getStatus',
  retrieveKey: '/admin/service/supporter/retrievekey'
};

const url = $request.url;

// 判断是否匹配特定的 URL 路径
const isTargetUrl = (url, path) => url.includes(path);

// 处理不同 URL 路径的逻辑
let responseBody;
if (isTargetUrl(url, URL_PATTERNS.validateDevice)) {
  responseBody = {
    cacheExpirationDays: 999,
    resultCode: 'GOOD',
    message: 'Device Valid'
  };
} else if (isTargetUrl(url, URL_PATTERNS.appstoreRegister)) {
  responseBody = {
    featId: "",
    registered: true,
    expDate: "2099-01-01",
    key: ""
  };
} else if (isTargetUrl(url, URL_PATTERNS.validate)) {
  responseBody = {
    featId: "",
    registered: true,
    expDate: "2099-01-01",
    key: ""
  };
} else if (isTargetUrl(url, URL_PATTERNS.getStatus)) {
  responseBody = {
    planType: "Cracked",
    deviceStatus: "",
    subscriptions: []
  };
} else if (isTargetUrl(url, URL_PATTERNS.retrieveKey)) {
  responseBody = {
    Success: false,
    ErrorMessage: "Supporter not found"
  };
}

// 如果匹配到目标 URL，则伪造响应
if (responseBody) {
  const status = 200; // 强制返回成功状态
  const headers = $response.headers; // 保留原始头部信息
  const body = JSON.stringify(responseBody); // 转为字符串的 JSON 响应

  $done({ status, headers, body });
} else {
  // 如果不匹配任何目标 URL，直接返回原始响应
  $done({});
}
