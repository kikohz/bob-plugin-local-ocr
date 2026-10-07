// Bob 本地 OCR 插件：把截图转发给 127.0.0.1 上的 bob-local-ocr 服务。
// 注意：Bob 插件运行在 JavaScriptCore 中，入口必须是顶层函数，不支持 ESM。

// Bob 语言代码 -> Vision 语言代码
var LANGUAGE_MAP = {
  'zh-Hans': 'zh-Hans',
  'zh-Hant': 'zh-Hant',
  yue: 'yue-Hans',
  en: 'en-US',
  ja: 'ja-JP',
  ko: 'ko-KR',
  fr: 'fr-FR',
  de: 'de-DE',
  es: 'es-ES',
  it: 'it-IT',
  pt: 'pt-BR',
  ru: 'ru-RU',
  uk: 'uk-UA',
  th: 'th-TH',
  vi: 'vi-VT',
  ar: 'ar-SA',
  tr: 'tr-TR',
  id: 'id-ID',
  cs: 'cs-CZ',
  da: 'da-DK',
  nl: 'nl-NL',
  no: 'nb-NO',
  ms: 'ms-MY',
  pl: 'pl-PL',
  ro: 'ro-RO',
  sv: 'sv-SE',
  fi: 'fi-FI',
  hi: 'hi-IN',
  mr: 'mr-IN',
};

var DEFAULT_LANGUAGES = ['zh-Hans', 'en-US'];

function baseURL() {
  var port = String($option.port || '').trim() || '50888';
  return 'http://127.0.0.1:' + port;
}

function supportLanguages() {
  return ['auto'].concat(Object.keys(LANGUAGE_MAP));
}

function supportBoundingBox() {
  return true;
}

function pluginTimeoutInterval() {
  return 60;
}

// 手动指定语言时只用该语言（附带英文，方便识别中英混排）；自动时让 Vision 自己判断，
// 并把 Bob 预测的语言放在最前面。
function buildLanguages(query) {
  var manual = query.from && query.from !== 'auto';
  var first = LANGUAGE_MAP[manual ? query.from : query.detectFrom];
  var list = first ? [first] : [];
  var extra = manual ? ['en-US'] : DEFAULT_LANGUAGES;
  extra.forEach(function (lang) {
    if (list.indexOf(lang) === -1) list.push(lang);
  });
  return { languages: list, autoDetect: !manual };
}

function toBoundingBox(box) {
  var left = box.x;
  var top = box.y;
  var right = box.x + box.w;
  var bottom = box.y + box.h;
  return {
    points: [
      { x: left, y: top },
      { x: right, y: top },
      { x: left, y: bottom },
      { x: right, y: bottom },
    ],
  };
}

function serviceDownError(detail) {
  return {
    type: 'network',
    message: '无法连接本地 OCR 服务（' + baseURL() + '），请确认 bob-local-ocr 正在运行',
    addition: detail,
  };
}

function ocr(query, completion) {
  var lang = buildLanguages(query);
  $http.request({
    method: 'POST',
    url: baseURL() + '/ocr',
    header: { 'Content-Type': 'application/json' },
    body: {
      image: query.image.toBase64(),
      languages: lang.languages,
      autoDetect: lang.autoDetect,
    },
    timeout: 55,
    handler: function (resp) {
      if (resp.error) {
        completion({ error: serviceDownError(String(resp.error.localizedDescription || resp.error)) });
        return;
      }
      var data = resp.data;
      var status = resp.response && resp.response.statusCode;
      if (status !== 200 || !data || !data.texts) {
        completion({
          error: {
            type: 'api',
            message: (data && data.error) || '本地 OCR 服务返回异常（HTTP ' + status + '）',
            addition: data,
          },
        });
        return;
      }
      if (data.texts.length === 0) {
        completion({ error: { type: 'notFound', message: '图片中没有识别到文字' } });
        return;
      }
      completion({
        result: {
          from: query.detectFrom,
          texts: data.texts.map(function (line) {
            return { text: line.text, boundingBox: toBoundingBox(line.box) };
          }),
          raw: { elapsedMs: data.elapsedMs },
        },
      });
    },
  });
}

function pluginValidate(completion) {
  $http.request({
    method: 'GET',
    url: baseURL() + '/health',
    timeout: 5,
    handler: function (resp) {
      if (resp.error || !resp.data || !resp.data.ok) {
        completion({ result: false, error: serviceDownError(resp.error ? String(resp.error) : resp.data) });
        return;
      }
      completion({ result: true });
    },
  });
}
