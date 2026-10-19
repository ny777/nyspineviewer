/**
 * 全屏 WebView 承载 spine-ts 播放页。
 * 虚拟主机 https://spine.local：所有请求经 onInterceptRequest 本地路由
 * （/web/* → rawfile，/models/<id>/<file> → filesDir/models 沙箱文件），
 * 不发生任何真实网络访问。onInterceptRequest 运行在非 UI 线程，禁止触碰 UI 状态。
 */
import { webview } from '@kit.ArkWeb';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const VIRTUAL_HOST = 'https://spine.local';
const HOST_PREFIX = `${VIRTUAL_HOST}/`;
const LOG_DOMAIN = 0x0031;
const TAG = 'SpineWebView';

/**
 * javaScriptProxy 注册的桥对象。同步方法回调运行在主线程，
 * 可直接更新调用方闭包内的 @State。
 */
export class SpineBridgeProxy {
  modelLoadedHandler: (json: string) => void = (json: string) => {
  };
  errorHandler: (json: string) => void = (json: string) => {
  };
  captureChunkHandler: (json: string) => void = (json: string) => {
  };
  captureDoneHandler: (json: string) => void = (json: string) => {
  };
  transformChangedHandler: (json: string) => void = (json: string) => {
  };
  animationChangedHandler: (json: string) => void = (json: string) => {
  };

  onModelLoaded(json: string): void {
    this.modelLoadedHandler(json);
  }

  onError(json: string): void {
    this.errorHandler(json);
  }

  onCaptureFrameChunk(json: string): void {
    this.captureChunkHandler(json);
  }

  onCaptureFrame(json: string): void {
    this.captureDoneHandler(json);
  }

  onTransformChanged(json: string): void {
    this.transformChangedHandler(json);
  }

  onAnimationChanged(json: string): void {
    this.animationChangedHandler(json);
  }
}

@Component
export struct SpineWebView {
  controller: webview.WebviewController = new webview.WebviewController();
  bridge: SpineBridgeProxy = new SpineBridgeProxy();
  /** 模型根目录沙箱路径（<filesDir>/models）。 */
  modelsRoot: string = '';
  onPageReady: () => void = () => {
  };

  build() {
    Web({ src: `${VIRTUAL_HOST}/web/index.html`, controller: this.controller })
      .javaScriptProxy({
        object: this.bridge,
        name: 'spineBridge',
        methodList: ['onModelLoaded', 'onError', 'onCaptureFrameChunk', 'onCaptureFrame',
          'onTransformChanged', 'onAnimationChanged'],
        controller: this.controller
      })
      .onInterceptRequest((event: OnInterceptRequestEvent) => this.routeRequest(event.request))
      .onConsole((event: OnConsoleEvent) => {
        const message = event.message;
        hilog.info(LOG_DOMAIN, TAG, '[web] %{public}s:%{public}d %{public}s',
          message.getSourceId(), message.getLineNumber(), message.getMessage());
        return false;
      })
      .javaScriptAccess(true)
      .zoomAccess(false)
      .fileAccess(false)
      .onPageEnd(() => {
        this.onPageReady();
      })
      .width('100%')
      .height('100%')
  }

  /** 虚拟主机路由分发：/web/* → rawfile；/models/* → 沙箱模型文件；其余 404。 */
  private routeRequest(request: WebResourceRequest): WebResourceResponse {
    const url = request.getRequestUrl();
    const queryIdx = url.indexOf('?');
    const path = queryIdx >= 0 ? url.substring(0, queryIdx) : url;
    if (!path.startsWith(HOST_PREFIX)) {
      return buildNotFoundResponse();
    }
    const rel = path.substring(HOST_PREFIX.length);
    if (rel.startsWith('web/')) {
      return this.routeWebFile(rel.substring('web/'.length));
    }
    if (rel.startsWith('models/')) {
      return this.routeModelFile(rel.substring('models/'.length));
    }
    return buildNotFoundResponse();
  }

  /** rawfile 内 web 静态资源（index.html / player-host.js / runtimes/*.js）。 */
  private routeWebFile(relPath: string): WebResourceResponse {
    if (relPath.length === 0 || relPath.startsWith('/') || relPath.includes('..')) {
      return buildNotFoundResponse();
    }
    const response = new WebResourceResponse();
    response.setResponseData($rawfile(`web/${relPath}`));
    response.setResponseMimeType(mimeFromName(relPath));
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    return response;
  }

  /** 沙箱模型文件（filesDir/models/<uuid>/<file>，路径段逐层守卫）。 */
  private routeModelFile(relPath: string): WebResourceResponse {
    const slashIdx = relPath.indexOf('/');
    if (slashIdx <= 0 || slashIdx === relPath.length - 1) {
      return buildNotFoundResponse();
    }
    let modelId = '';
    let fileName = '';
    try {
      modelId = decodeURIComponent(relPath.substring(0, slashIdx));
      fileName = decodeURIComponent(relPath.substring(slashIdx + 1));
    } catch (err) {
      return buildNotFoundResponse();
    }
    if (modelId.length === 0 || fileName.length === 0 || modelId.includes('/') ||
      fileName.includes('/') || modelId.includes('..') || fileName.includes('..') ||
      this.modelsRoot.length === 0) {
      return buildNotFoundResponse();
    }
    const filePath = `${this.modelsRoot}/${modelId}/${fileName}`;
    let fd = -1;
    try {
      if (!fileIo.accessSync(filePath, fileIo.AccessModeType.EXIST)) {
        return buildNotFoundResponse();
      }
      const stat = fileIo.statSync(filePath);
      const buffer = new ArrayBuffer(stat.size);
      fd = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY).fd;
      fileIo.readSync(fd, buffer);
      const response = new WebResourceResponse();
      response.setResponseData(buffer);
      response.setResponseMimeType(mimeFromName(fileName));
      response.setResponseCode(200);
      response.setReasonMessage('OK');
      return response;
    } catch (err) {
      return buildNotFoundResponse();
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (err) {
          // 忽略关闭失败
        }
      }
    }
  }
}

/** 404 响应。 */
function buildNotFoundResponse(): WebResourceResponse {
  const response = new WebResourceResponse();
  response.setResponseData('Not Found');
  response.setResponseMimeType('text/plain');
  response.setResponseCode(404);
  response.setReasonMessage('Not Found');
  return response;
}

/** 按扩展名推断 MIME。 */
function mimeFromName(name: string): string {
  const lower = name.toLowerCase();
  if (lower.endsWith('.html')) {
    return 'text/html';
  }
  if (lower.endsWith('.js')) {
    return 'application/javascript';
  }
  if (lower.endsWith('.css')) {
    return 'text/css';
  }
  if (lower.endsWith('.json')) {
    return 'application/json';
  }
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  if (lower.endsWith('.txt') || lower.endsWith('.atlas')) {
    return 'text/plain';
  }
  return 'application/octet-stream';
}
