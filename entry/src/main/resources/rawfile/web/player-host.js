/**
 * Spine 播放宿主（ArkWeb ↔ spine-ts 多版本运行时 3.8 / 4.0 / 4.1 / 4.2）。
 *
 * 行为蓝本（SpineV41Adapter.kt / SpineGlRenderer.kt）：
 *  - AnimationStateData.defaultMix = 0.2
 *  - 多选皮肤：新建 Skin("__combined__") 依次 addSkin 叠加 → setSkin → setSlotsToSetupPose
 *  - 动画数据损坏：捕获异常 → 停用 AnimationState → setToSetupPose() 静态兜底
 *  - 模型居中公式：x = w/2 + posX*w, y = h/2 + posY*h（posX/posY 为屏幕占比）
 *  - 双槽层级：slot1 先画（后层），slot0 后画（前层）
 *
 * 消息协议：与 ArkTS BridgeProtocol.ets 严格一致。
 *   ArkTS→Web: window.SpineHost.cmd({cmd: 'loadModel', ...})
 *   Web→ArkTS: window.spineBridge.onModelLoaded(json) / onError / onCaptureFrameChunk /
 *              onCaptureFrame / onTransformChanged / onAnimationChanged / onScreenTap
 */
(function () {
  'use strict';

  var COMBINED_SKIN = '__combined__';
  var RUNTIME_PATH = '/web/runtimes/spine-';
  var MODEL_BASE = '/models/';
  var TAP_SLOP_PX = 10;
  var TAP_TIMEOUT_MS = 250;
  var MIN_SCALE = 0.2;
  var MAX_SCALE = 5.0;
  var MIN_FPS = 15;
  var MAX_FPS = 120;
  var CAPTURE_CHUNK_SIZE = 262144; // 256KB base64 切片
  var defaultMixSec = 0.2; // 动画过渡混合秒数（AnimationStateData.defaultMix，setMix 可调）

  var canvas = document.getElementById('spine-canvas');
  var gl = null;
  var renderers = {}; // versionKey -> SceneRenderer（多版本共存，各自惰性创建）
  var runtimeCache = {}; // version -> spine namespace
  var playing = true;
  var tapSwitch = true; // 点击预览切换动画开关（对齐 Android tap_switch_animation）
  var fps = 60;
  var lastFrameTime = 0;
  var bgColor = [0.059, 0.090, 0.165, 1.0]; // #0F172A
  // 自定义背景图：图覆盖色，移除回色（对齐 Android SpineGlRenderer bg 分支）
  var bgImage = null; // HTMLImageElement（解码完成后建纹理）
  var bgTex = null; // WebGLTexture
  var bgImageW = 0;
  var bgImageH = 0;
  var bgProgram = null; // 背景全屏四边形 program（pos+uv）
  var bgVbo = null;
  var gestureSlot = 0;
  var diag = { raf: 0, drawn: 0, last: 0, dt: 0 };

  function SlotState() {
    this.reset();
  }
  SlotState.prototype.reset = function () {
    this.status = 'empty'; // empty | loading | loaded | error
    this.modelId = '';
    this.version = '';
    this.skelFile = '';
    this.atlasFile = '';
    this.pma = true;
    this.configScale = 1; // config.json scale：Spine 加载器缩放（非用户变换缩放）
    this.idleMotion = ''; // config.json idle_motion：加载完成后的动作兜底链（对应 Android 渲染器链）
    this.skeleton = null;
    this.skeletonData = null;
    this.state = null;
    this.animationError = false;
    this.currentAnimationName = '';
    this.rt = null; // 本槽位对应的 spine 运行时命名空间（多版本共存）
    // 期望状态：加载完成前先暂存，加载后统一应用（对应 Android 版期望状态语义）
    this.desired = { animation: null, loop: true, skins: [], transform: null };
    this.transform = { scale: 1, x: 0, y: 0 };
    this.textures = [];
    this.visible = true; // 槽位显隐（会话级开关，隐藏时渲染循环整体跳过）
    this.mirrored = false; // 槽位水平镜像（scaleX 取反，按槽位持久化偏好恢复）
    this.alpha = 1; // 槽位整体透明度（skeleton.color.a，按槽位持久化偏好恢复；LOAD_MODEL 重置为 1，缩略图天然不透明）
    this.speed = 1; // 槽位播放速度 0.25-2（AnimationState.timeScale，按槽位持久化偏好恢复）
    this.playlist = { enabled: false, names: [], index: 0 }; // 循环轮播列表：各项播完一次 complete 自动推进
    this.tapMotions = []; // config.json tap_motions：[{area, anim}]（bounding box 命中区域 → 反应动画）
    this.tapAnimName = ''; // 正在播的点击反应动画名（不改动 currentAnimationName，chip 保持底层动画）
    this.tapReturnName = ''; // 反应结束后要回放的底层动画名（轮播关闭时使用；轮播开启经 playlist.index 恢复）
  };

  var slots = [new SlotState(), new SlotState()];

  // ==================== 桥回调（javaScriptProxy 注入的 ArkTS 对象） ====================

  function bridgeCall(method, json) {
    try {
      if (window.spineBridge && typeof window.spineBridge[method] === 'function') {
        window.spineBridge[method](json);
      }
    } catch (e) {
      // 桥未就绪或参数序列化失败：静默，避免打断渲染循环
    }
  }

  function notifyModelLoaded(slotIdx, modelId, skeletonData) {
    var animations = [];
    var skins = [];
    var i;
    if (skeletonData.animations) {
      for (i = 0; i < skeletonData.animations.length; i++) {
        animations.push(skeletonData.animations[i].name);
      }
    }
    if (skeletonData.skins) {
      for (i = 0; i < skeletonData.skins.length; i++) {
        skins.push(skeletonData.skins[i].name);
      }
    }
    bridgeCall('onModelLoaded', JSON.stringify({
      slot: slotIdx,
      modelId: modelId,
      animations: animations,
      skins: skins
    }));
  }

  function notifyError(slotIdx, code, message) {
    try {
      console.error('[SpineHost] error ' + code + ': ' + message);
    } catch (e) {
      // console 不可用时忽略
    }
    bridgeCall('onError', JSON.stringify({
      slot: slotIdx,
      code: code,
      message: String(message)
    }));
  }

  // ==================== 运行时加载（版本分发器，支持 3.8 / 4.0 / 4.1 / 4.2） ====================

  function ensureRuntime(version) {
    return new Promise(function (resolve, reject) {
      if (runtimeCache[version]) {
        resolve(runtimeCache[version]);
        return;
      }
      var script = document.createElement('script');
      script.src = RUNTIME_PATH + version + '.js';
      script.onload = function () {
        var rt = window.spineRuntimes && window.spineRuntimes[version];
        if (rt) {
          runtimeCache[version] = rt;
          console.log('[spine] runtime ' + version + ' loaded & registered');
          resolve(rt);
        } else {
          reject(new Error('runtime ' + version + ' 未集成（bundle 未注册 spineRuntimes）'));
        }
      };
      script.onerror = function () {
        reject(new Error('无法加载 runtime bundle: spine-' + version + '.js'));
      };
      document.head.appendChild(script);
    });
  }

  // ==================== 资源加载 ====================

  function modelUrl(modelId, fileName) {
    return MODEL_BASE + encodeURIComponent(modelId) + '/' + encodeURIComponent(fileName);
  }

  function fetchArrayBuffer(url) {
    return new Promise(function (resolve, reject) {
      var xhr = new XMLHttpRequest();
      xhr.open('GET', url);
      xhr.responseType = 'arraybuffer';
      xhr.onload = function () {
        if (xhr.status >= 200 && xhr.status < 300) {
          resolve(xhr.response);
        } else {
          reject(new Error('GET ' + url + ' 失败: ' + xhr.status));
        }
      };
      xhr.onerror = function () {
        reject(new Error('GET ' + url + ' 网络错误'));
      };
      xhr.send();
    });
  }

  function fetchText(url) {
    return new Promise(function (resolve, reject) {
      var xhr = new XMLHttpRequest();
      xhr.open('GET', url);
      xhr.onload = function () {
        if (xhr.status >= 200 && xhr.status < 300) {
          resolve(xhr.responseText);
        } else {
          reject(new Error('GET ' + url + ' 失败: ' + xhr.status));
        }
      };
      xhr.onerror = function () {
        reject(new Error('GET ' + url + ' 网络错误'));
      };
      xhr.send();
    });
  }

  function loadImage(url) {
    return new Promise(function (resolve, reject) {
      var img = new Image();
      img.onload = function () { resolve(img); };
      img.onerror = function () { reject(new Error('加载贴图失败: ' + url)); };
      img.src = url;
    });
  }

  // 3.8 专用：轻量预解析 atlas 文本，提取 page 名与 mipmap 标记。
  // 与 3.8 TextureAtlas 的块解析对齐：trim；空行结束当前 page 块；无当前 page 时该行为 page 名。
  function parseAtlasPages(atlasText) {
    var result = [];
    var lines = String(atlasText).split(/\r\n|\r|\n/);
    var currentPage = null;
    var i;
    for (i = 0; i < lines.length; i++) {
      var line = lines[i].trim();
      if (line.length === 0) {
        currentPage = null;
      } else if (currentPage === null) {
        currentPage = { name: line, mipmaps: false };
        result.push(currentPage);
      } else if (/mipmap/i.test(line)) {
        currentPage.mipmaps = true;
      }
    }
    return result;
  }

  // ==================== 命令处理 ====================

  function cmdLoadModel(msg) {
    var slotIdx = clampSlot(msg.slot);
    var slot = slots[slotIdx];
    disposeSlot(slotIdx);
    slot.reset();
    slot.visible = true; // 加载即显示：新设置的模型必然可见，避免"设置了却看不见"
    slot.status = 'loading';
    slot.modelId = String(msg.modelId || '');
    slot.version = String(msg.version || '4.1');
    slot.skelFile = String(msg.skelFile || '');
    slot.atlasFile = String(msg.atlasFile || '');
    slot.pma = !!msg.pma;
    slot.configScale = (typeof msg.configScale === 'number' && isFinite(msg.configScale) && msg.configScale > 0)
      ? msg.configScale : 1;
    slot.idleMotion = typeof msg.idleMotion === 'string' ? msg.idleMotion : '';
    slot.tapMotions = [];
    if (msg.tapMotions && msg.tapMotions.length) {
      for (var tm = 0; tm < msg.tapMotions.length; tm++) {
        var tmEntry = msg.tapMotions[tm];
        if (tmEntry && typeof tmEntry.area === 'string' && typeof tmEntry.anim === 'string' &&
          tmEntry.area.length > 0 && tmEntry.anim.length > 0) {
          slot.tapMotions.push({ area: tmEntry.area, anim: tmEntry.anim });
        }
      }
    }

    if (!slot.modelId || !slot.skelFile || !slot.atlasFile) {
      slot.status = 'error';
      notifyError(slotIdx, 'LOAD_FAILED', 'loadModel 缺少 modelId/skelFile/atlasFile');
      return;
    }

    ensureRuntime(slot.version).then(function (spine) {
      return fetchText(modelUrl(slot.modelId, slot.atlasFile)).then(function (atlasText) {
        if (slot.version === '3.8') {
          // 3.8: TextureAtlas 构造需要同步 textureLoader（解析期立即 setFilters 且用贴图尺寸计算 UV），
          // 必须先并行加载全部 page 图，再以同步 loader 构造 atlas；纹理归 slot.textures 统一释放。
          var pages38 = parseAtlasPages(atlasText);
          var jobs38 = [];
          var j;
          for (j = 0; j < pages38.length; j++) {
            jobs38.push(loadImage(modelUrl(slot.modelId, pages38[j].name)));
          }
          return Promise.all(jobs38).then(function (imgs) {
            var imgMap = {};
            var mipMap = {};
            var k;
            for (k = 0; k < pages38.length; k++) {
              imgMap[pages38[k].name] = imgs[k];
              mipMap[pages38[k].name] = pages38[k].mipmaps;
            }
            return new spine.TextureAtlas(atlasText, function (path) {
              var texture = new spine.GLTexture(gl, imgMap[path], !!mipMap[path]);
              slot.textures.push(texture);
              return texture;
            });
          });
        }
        var atlas = new spine.TextureAtlas(atlasText);
        var pages = atlas.pages || [];
        var textureJobs = [];
        var i;
        for (i = 0; i < pages.length; i++) {
          textureJobs.push(loadImage(modelUrl(slot.modelId, pages[i].name)).then(function (page) {
            return function (img) {
              var texture = new spine.GLTexture(gl, img);
              page.setTexture(texture);
              slot.textures.push(texture);
            };
          }(pages[i])));
        }
        return Promise.all(textureJobs).then(function () {
          return atlas;
        });
      }).then(function (atlas) {
        var attachmentLoader = new spine.AtlasAttachmentLoader(atlas);
        var isJson = slot.skelFile.toLowerCase().endsWith('.json');
        var data;
        if (isJson) {
          return fetchText(modelUrl(slot.modelId, slot.skelFile)).then(function (text) {
            var jsonReader = new spine.SkeletonJson(attachmentLoader);
            jsonReader.scale = slot.configScale;
            return jsonReader.readSkeletonData(text);
          });
        }
        return fetchArrayBuffer(modelUrl(slot.modelId, slot.skelFile)).then(function (buf) {
          var binaryReader = new spine.SkeletonBinary(attachmentLoader);
          binaryReader.scale = slot.configScale;
          return binaryReader.readSkeletonData(new Uint8Array(buf));
        });
      }).then(function (skeletonData) {
        var spine = runtimeCache[slot.version];
        slot.rt = spine; // 供渲染循环做版本分支（如 4.2 Physics）
        var skeleton = new spine.Skeleton(skeletonData);
        var stateData = new spine.AnimationStateData(skeletonData);
        stateData.defaultMix = defaultMixSec; // 过渡混合秒数（对齐 4.1 行为蓝本默认 0.2，setMix 可调）
        var animState = new spine.AnimationState(stateData);
        animState.timeScale = slot.speed; // 槽位播放速度
        animState.addListener({ complete: function (entry) { onTrackComplete(slotIdx, entry); } });
        slot.skeletonData = skeletonData;
        slot.skeleton = skeleton;
        slot.state = animState;
        slot.status = 'loaded';
        slot.animationError = false;
        console.log('[spine] modelLoaded slot=' + slotIdx + ' anims=' +
          (skeletonData.animations ? skeletonData.animations.length : 0) +
          ' skins=' + (skeletonData.skins ? skeletonData.skins.length : 0));
        applyDesired(slotIdx);
        // 动作兜底链（对齐 Android 渲染器）：上层指定（desired）> config.idle_motion > 第一个动作。
        // 二进制模型导入时 meta 是占位值，ArkTS 不下发动作，由这里用真实动画名解析后回报同步。
        if (!slot.currentAnimationName && skeletonData.animations && skeletonData.animations.length > 0) {
          var anims0 = skeletonData.animations;
          var chosen = '';
          var k;
          if (slot.idleMotion) {
            for (k = 0; k < anims0.length; k++) {
              if (anims0[k].name === slot.idleMotion) {
                chosen = slot.idleMotion;
                break;
              }
            }
          }
          if (!chosen) {
            chosen = anims0[0].name;
          }
          slot.desired.animation = chosen;
          slot.desired.loop = true;
          playAnimationInternal(slotIdx, chosen, true, true);
          bridgeCall('onAnimationChanged', JSON.stringify({
            slot: slotIdx,
            name: chosen
          }));
        }
        // 轮播恢复：加载命令链中已暂存的 playlist（加载期 SET_PLAYLIST 提前到达）在模型就绪后统一启播；
        // 起始项 = 当前动画在列表中的位置（无则第 0 项并回报同步）。
        if (slot.playlist.enabled && slot.playlist.names.length > 0) {
          var plValid = filterExistingAnimations(slot, slot.playlist.names);
          if (plValid.length > 0) {
            slot.playlist.names = plValid;
            var plStart = plValid.indexOf(slot.currentAnimationName);
            playPlaylistItem(slotIdx, plStart >= 0 ? plStart : 0, plStart < 0);
          } else {
            slot.playlist.enabled = false;
            slot.playlist.names = [];
          }
        }
        notifyModelLoaded(slotIdx, slot.modelId, skeletonData);
        renderFrame(0); // 立即出画面，不等下一帧
      });
    }).catch(function (err) {
      slot.status = 'error';
      notifyError(slotIdx, 'LOAD_FAILED', (err && err.message) || err);
    });
  }

  function applyDesired(slotIdx) {
    var slot = slots[slotIdx];
    var d = slot.desired;
    if (d.animation !== null) {
      playAnimationInternal(slotIdx, d.animation, d.loop, true);
    }
    if (d.skins && d.skins.length > 0) {
      applySkins(slotIdx, d.skins);
    }
    if (d.transform) {
      slot.transform.scale = d.transform.scale;
      slot.transform.x = d.transform.x;
      slot.transform.y = d.transform.y;
    }
  }

  function playAnimationInternal(slotIdx, name, loop, silentIfMissing) {
    var slot = slots[slotIdx];
    if (!slot.skeletonData || !slot.state) {
      return;
    }
    try {
      var found = false;
      var anims = slot.skeletonData.animations || [];
      for (var i = 0; i < anims.length; i++) {
        if (anims[i].name === name) {
          found = true;
          break;
        }
      }
      if (!found) {
        if (!silentIfMissing) {
          notifyError(slotIdx, 'ANIMATION_NOT_FOUND', '动画不存在: ' + name);
        }
        return;
      }
      slot.state.setAnimation(0, name, !!loop);
      slot.currentAnimationName = name;
      slot.animationError = false;
      console.log('[spine] playAnim slot=' + slotIdx + ' name=' + name + ' loop=' + !!loop + ' ok');
    } catch (e) {
      notifyError(slotIdx, 'ANIMATION_ERROR', (e && e.message) || e);
    }
  }

  function cmdPlayAnimation(msg) {
    var slotIdx = clampSlot(msg.slot);
    var slot = slots[slotIdx];
    var name = String(msg.name || '');
    var loop = msg.loop !== false;
    slot.tapAnimName = ''; // 新动画命令清理点击反应残留状态
    slot.tapReturnName = '';
    slot.desired.animation = name;
    slot.desired.loop = loop;
    if (slot.status === 'loaded') {
      playAnimationInternal(slotIdx, name, loop, false);
      renderFrame(0);
    }
  }

  function applySkins(slotIdx, skins) {
    var slot = slots[slotIdx];
    var skel = slot.skeleton;
    if (!skel || !slot.skeletonData) {
      return;
    }
    try {
      if (skins.length === 1) {
        skel.setSkinByName(skins[0]); // 不存在时抛错，由 catch 兜底
        skel.setSlotsToSetupPose();
      } else {
        var spine = runtimeCache[slot.version];
        var combined = new spine.Skin(COMBINED_SKIN);
        for (var i = 0; i < skins.length; i++) {
          var src = slot.skeletonData.findSkin(skins[i]);
          if (src) {
            combined.addSkin(src); // 后合并的覆盖先合并的同名 slot+attachment
          }
        }
        skel.setSkin(combined);
        skel.setSlotsToSetupPose();
      }
    } catch (e) {
      notifyError(slotIdx, 'SKIN_ERROR', (e && e.message) || e);
    }
  }

  function cmdSetSkins(msg) {
    var slotIdx = clampSlot(msg.slot);
    var slot = slots[slotIdx];
    var skins = [];
    if (msg.skins && msg.skins.length) {
      for (var i = 0; i < msg.skins.length; i++) {
        skins.push(String(msg.skins[i]));
      }
    }
    slot.desired.skins = skins;
    if (slot.status === 'loaded') {
      applySkins(slotIdx, skins);
      renderFrame(0);
    }
  }

  function cmdSetTransform(msg) {
    var slotIdx = clampSlot(msg.slot);
    var slot = slots[slotIdx];
    slot.transform.scale = num(msg.scale, 1);
    slot.transform.x = num(msg.x, 0);
    slot.transform.y = num(msg.y, 0);
    if (slot.status === 'loaded') {
      renderFrame(0);
    }
  }

  function cmdSetPma(msg) {
    var slotIdx = clampSlot(msg.slot);
    slots[slotIdx].pma = !!msg.pma;
    if (slots[slotIdx].status === 'loaded') {
      renderFrame(0);
    }
  }

  function cmdSetPlaying(msg) {
    playing = !!msg.playing;
    renderFrame(0); // 暂停时也刷新一帧静态画面
  }

  function cmdSetTapSwitch(msg) {
    tapSwitch = !!msg.tapSwitch;
  }

  function cmdSetFps(msg) {
    var value = Math.round(num(msg.fps, 60));
    fps = Math.min(MAX_FPS, Math.max(MIN_FPS, value));
  }

  function cmdSetBackgroundColor(msg) {
    var color = parseColor(String(msg.color || '#0F172A'));
    if (color) {
      bgColor = color;
      renderFrame(0);
    }
  }

  // 自定义背景图：url 空表示移除（删纹理回纯色）；非空经虚拟域 /bg/ 加载
  function cmdSetBackgroundImage(msg) {
    var url = typeof msg.url === 'string' ? msg.url : '';
    deleteBgTexture();
    bgImage = null;
    bgImageW = 0;
    bgImageH = 0;
    if (!url) {
      renderFrame(0);
      return;
    }
    var img = new Image();
    img.onload = function () {
      bgImage = img;
      bgImageW = img.naturalWidth || img.width;
      bgImageH = img.naturalHeight || img.height;
      if (gl) {
        createBgTexture();
      }
      renderFrame(0);
    };
    img.onerror = function () {
      notifyError(0, 'BG_LOAD_FAILED', '背景图加载失败: ' + url);
    };
    img.src = url;
  }

  function deleteBgTexture() {
    if (bgTex && gl) {
      try {
        gl.deleteTexture(bgTex);
      } catch (e) {
        // 忽略释放失败
      }
    }
    bgTex = null;
  }

  function createBgTexture() {
    deleteBgTexture();
    bgTex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, bgTex);
    // 不设 UNPACK_FLIP_Y：四边形 uv 已按「v=0 = 图顶部」布局（y=+1 顶点取 v=0）
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bgImage);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  }

  function compileShader(type, source) {
    var shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      console.log('[spine] shader error: ' + gl.getShaderInfoLog(shader));
      gl.deleteShader(shader);
      return null;
    }
    return shader;
  }

  // 背景全屏四边形 program（一次编译，pos+uv 交错 VBO 常驻）
  function ensureBgProgram() {
    if (bgProgram) {
      return bgProgram;
    }
    var vs = compileShader(gl.VERTEX_SHADER,
      'attribute vec2 aPos; attribute vec2 aUv; uniform vec2 uPosScale; varying vec2 vUv;' +
      'void main(){ vUv = aUv; gl_Position = vec4(aPos * uPosScale, 0.0, 1.0); }');
    var fs = compileShader(gl.FRAGMENT_SHADER,
      'precision mediump float; varying vec2 vUv; uniform sampler2D uTex;' +
      'void main(){ gl_FragColor = texture2D(uTex, vUv); }');
    if (!vs || !fs) {
      return null;
    }
    var program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      console.log('[spine] bg program link error: ' + gl.getProgramInfoLog(program));
      gl.deleteProgram(program);
      return null;
    }
    // TRIANGLE_STRIP 顶点顺序：左下/右下/左上/右上；uv 与顶点配对
    var quad = new Float32Array([
      -1, -1, 0, 1,
      1, -1, 1, 1,
      -1, 1, 0, 0,
      1, 1, 1, 0
    ]);
    bgVbo = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, bgVbo);
    gl.bufferData(gl.ARRAY_BUFFER, quad, gl.STATIC_DRAW);
    bgProgram = program;
    return bgProgram;
  }

  // cover-fit 数学照抄 Android：coverScale = max(vw/imgW, vh/imgH)，居中等比不拉伸
  function drawBackground(size) {
    if (!bgTex || !bgImage || bgImageW <= 0 || bgImageH <= 0) {
      return;
    }
    var program = ensureBgProgram();
    if (!program) {
      return;
    }
    var canvasAspect = size.w / size.h;
    var imgAspect = bgImageW / bgImageH;
    var ax = 1;
    var ay = 1;
    if (imgAspect > canvasAspect) {
      ax = imgAspect / canvasAspect;
    } else {
      ay = canvasAspect / imgAspect;
    }
    gl.useProgram(program);
    gl.bindBuffer(gl.ARRAY_BUFFER, bgVbo);
    var posLoc = gl.getAttribLocation(program, 'aPos');
    var uvLoc = gl.getAttribLocation(program, 'aUv');
    gl.enableVertexAttribArray(posLoc);
    gl.enableVertexAttribArray(uvLoc);
    gl.vertexAttribPointer(posLoc, 2, gl.FLOAT, false, 16, 0);
    gl.vertexAttribPointer(uvLoc, 2, gl.FLOAT, false, 16, 8);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, bgTex);
    gl.uniform1i(gl.getUniformLocation(program, 'uTex'), 0);
    gl.disable(gl.BLEND);
    // 等比 cover：按纵横比缩放 NDC 半宽/半高，超界部分被视口裁剪
    gl.uniform2f(gl.getUniformLocation(program, 'uPosScale'), ax, ay);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    gl.disableVertexAttribArray(posLoc);
    gl.disableVertexAttribArray(uvLoc);
  }

  function cmdSetGestureSlot(msg) {
    gestureSlot = clampSlot(msg.slot);
  }

  function cmdSetSlotVisible(msg) {
    var slotIdx = clampSlot(msg.slot);
    slots[slotIdx].visible = !!msg.visible;
    renderFrame(0);
  }

  function cmdSetMirror(msg) {
    var slotIdx = clampSlot(msg.slot);
    var slot = slots[slotIdx];
    slot.mirrored = !!msg.mirror;
    if (slot.skeleton) {
      // 骨架就绪立即生效；未就绪只存标志（applySkeletonTransform 恒定乘入）
      applySkeletonTransform(slotIdx);
      renderFrame(0);
    }
  }

  function cmdSetAlpha(msg) {
    var slotIdx = clampSlot(msg.slot);
    var slot = slots[slotIdx];
    // 骨架未就绪只存值：渲染循环每帧幂等写入 skeleton.color.a
    slot.alpha = Math.min(1, Math.max(0, +msg.alpha || 1));
    renderFrame(0);
  }

  // 槽位播放速度 0.25-2（两位小数归一，与 ArkTS 侧同钳制）
  function cmdSetSpeed(msg) {
    var slotIdx = clampSlot(msg.slot);
    var slot = slots[slotIdx];
    var value = num(msg.speed, 1);
    slot.speed = Math.min(2, Math.max(0.25, Math.round(value * 100) / 100));
    if (slot.state) {
      slot.state.timeScale = slot.speed;
      renderFrame(0);
    }
  }

  // 全局动画过渡混合秒数 0-0.5：后续加载用新值，已加载槽位即时生效
  function cmdSetMix(msg) {
    var value = num(msg.mix, 0.2);
    defaultMixSec = Math.min(0.5, Math.max(0, Math.round(value * 100) / 100));
    for (var i = 0; i < slots.length; i++) {
      if (slots[i].state) {
        slots[i].state.data.defaultMix = defaultMixSec;
      }
    }
    renderFrame(0);
  }

  // 循环轮播列表：开启时起始项 = 当前动画在列表中的位置（无则第 0 项）；
  // 关闭时当前动画恢复单动画循环；加载未完成只暂存（cmdLoadModel 末尾统一启播）。
  function cmdSetPlaylist(msg) {
    var slotIdx = clampSlot(msg.slot);
    var slot = slots[slotIdx];
    var names = [];
    if (msg.names && msg.names.length) {
      for (var i = 0; i < msg.names.length; i++) {
        if (typeof msg.names[i] === 'string' && msg.names[i].length > 0) {
          names.push(msg.names[i]);
        }
      }
    }
    slot.playlist.enabled = !!msg.enabled && names.length > 0;
    slot.playlist.names = names;
    slot.playlist.index = 0;
    if (slot.status !== 'loaded') {
      return;
    }
    if (slot.playlist.enabled) {
      var valid = filterExistingAnimations(slot, names);
      if (valid.length === 0) {
        slot.playlist.enabled = false;
        slot.playlist.names = [];
        return;
      }
      slot.playlist.names = valid;
      var start = valid.indexOf(slot.currentAnimationName);
      playPlaylistItem(slotIdx, start >= 0 ? start : 0, start < 0);
    } else {
      slot.tapAnimName = '';
      slot.tapReturnName = '';
      if (slot.state && slot.currentAnimationName) {
        playAnimationInternal(slotIdx, slot.currentAnimationName, true, true);
        renderFrame(0);
      }
    }
  }

  function cmdClearSlot(msg) {
    var slotIdx = clampSlot(msg.slot);
    disposeSlot(slotIdx);
    slots[slotIdx].reset();
    renderFrame(0);
  }

  // 分块传输：base64 按 256KB 切片经 onCaptureFrameChunk 回传，
  // 全部发完后用 onCaptureFrame 发完成信号（规避单次桥回调体积上限）。
  function cmdCaptureFrame() {
    try {
      renderFrame(0); // 与 toDataURL 同一同步块内，避免 WebGL 缓冲被合成清空
      var dataUrl = canvas.toDataURL('image/png');
      var base64 = dataUrl.substring(dataUrl.indexOf(',') + 1);
      if (base64.length === 0) {
        notifyError(0, 'CAPTURE_ERROR', 'toDataURL 返回空数据');
        return;
      }
      var total = Math.ceil(base64.length / CAPTURE_CHUNK_SIZE);
      for (var i = 0; i < total; i++) {
        bridgeCall('onCaptureFrameChunk', JSON.stringify({
          index: i,
          total: total,
          data: base64.substring(i * CAPTURE_CHUNK_SIZE, Math.min((i + 1) * CAPTURE_CHUNK_SIZE, base64.length))
        }));
      }
      bridgeCall('onCaptureFrame', JSON.stringify({ done: true }));
    } catch (e) {
      notifyError(0, 'CAPTURE_ERROR', (e && e.message) || e);
    }
  }

  function disposeSlot(slotIdx) {
    var slot = slots[slotIdx];
    for (var i = 0; i < slot.textures.length; i++) {
      try {
        slot.textures[i].dispose();
      } catch (e) {
        // 忽略释放失败
      }
    }
  }

  // ==================== 轮播列表与点击反应 ====================

  /** 过滤 names 至 skeletonData 真实存在的动画（保序，去重不处理）。 */
  function filterExistingAnimations(slot, names) {
    var result = [];
    if (!slot.skeletonData || !slot.skeletonData.animations) {
      return result;
    }
    var anims = slot.skeletonData.animations;
    for (var i = 0; i < names.length; i++) {
      for (var k = 0; k < anims.length; k++) {
        if (anims[k].name === names[i]) {
          result.push(names[i]);
          break;
        }
      }
    }
    return result;
  }

  /**
   * 播放轮播列表指定索引项：loop=false 播完一次，由 onTrackComplete 推进下一项。
   * 不存在的名字向后环形跳过；全部不存在则关闭轮播。notify=true 时回报 onAnimationChanged。
   */
  function playPlaylistItem(slotIdx, index, notify) {
    var slot = slots[slotIdx];
    if (!slot.state || !slot.skeletonData) {
      return;
    }
    var valid = filterExistingAnimations(slot, slot.playlist.names);
    if (valid.length === 0) {
      slot.playlist.enabled = false;
      slot.playlist.names = [];
      return;
    }
    slot.playlist.names = valid;
    var i = ((Math.round(index) % valid.length) + valid.length) % valid.length;
    var name = valid[i];
    slot.playlist.index = i;
    try {
      slot.state.setAnimation(0, name, false);
      slot.currentAnimationName = name;
      slot.animationError = false;
    } catch (e) {
      notifyError(slotIdx, 'ANIMATION_ERROR', (e && e.message) || e);
      return;
    }
    if (notify) {
      bridgeCall('onAnimationChanged', JSON.stringify({ slot: slotIdx, name: name }));
    }
    renderFrame(0);
  }

  /** AnimationState complete 监听：点击反应结束 → 恢复；轮播项播完 → 下一项。 */
  function onTrackComplete(slotIdx, entry) {
    var slot = slots[slotIdx];
    if (!slot || !slot.state) {
      return;
    }
    var animName = entry && entry.animation ? entry.animation.name : '';
    if (slot.tapAnimName && animName === slot.tapAnimName) {
      restoreAfterTap(slotIdx);
      return;
    }
    if (slot.playlist.enabled && animName === slot.playlist.names[slot.playlist.index]) {
      playPlaylistItem(slotIdx, slot.playlist.index + 1, true);
    }
  }

  /** 点击反应播完恢复：轮播开启 → 重进当前轮播项；否则回放底层动画循环。 */
  function restoreAfterTap(slotIdx) {
    var slot = slots[slotIdx];
    slot.tapAnimName = '';
    if (slot.playlist.enabled && slot.playlist.names.length > 0 && slot.state) {
      playPlaylistItem(slotIdx, slot.playlist.index, false);
    } else if (slot.tapReturnName && slot.state) {
      playAnimationInternal(slotIdx, slot.tapReturnName, true, true);
      renderFrame(0);
    }
    slot.tapReturnName = '';
  }

  /**
   * config.json tap_motions 命中检测：世界坐标（y 向上）→ SkeletonBounds.containsPoint
   * 返回 BoundingBoxAttachment；先按 attachment 名匹配，再按承载 slot 名匹配。
   * 模型完全无 bounding box 时回退第一个 tap motion（整模型可点）。
   */
  function findTapMotionAt(slotIdx, pt) {
    var slot = slots[slotIdx];
    if (!slot.skeleton || !slot.skeletonData || !slot.rt || slot.tapMotions.length === 0) {
      return '';
    }
    var size = cssSize();
    var wx = pt.x;
    var wy = size.h - pt.y; // 屏幕 y 向下，世界 y 向上
    var bounds = new slot.rt.SkeletonBounds();
    bounds.update(slot.skeleton, false);
    var bbox = bounds.containsPoint(wx, wy);
    if (!bbox) {
      if (bounds.boundingBoxes.length === 0) {
        return slot.tapMotions[0].anim; // 无 bounding box 模型：整模型可点
      }
      return '';
    }
    var i;
    var j;
    for (i = 0; i < slot.tapMotions.length; i++) {
      if (slot.tapMotions[i].area === bbox.name) {
        return slot.tapMotions[i].anim;
      }
    }
    // 槽位名匹配：找承载该 attachment 的 slot
    var skelSlots = slot.skeleton.slots || [];
    for (i = 0; i < skelSlots.length; i++) {
      if (skelSlots[i].getAttachment() === bbox && skelSlots[i].data && skelSlots[i].data.name) {
        var slotName = skelSlots[i].data.name;
        for (j = 0; j < slot.tapMotions.length; j++) {
          if (slot.tapMotions[j].area === slotName) {
            return slot.tapMotions[j].anim;
          }
        }
        break;
      }
    }
    return '';
  }

  /**
   * 播放点击反应动画：loop=false 播完一次经 restoreAfterTap 恢复；
   * 不改 currentAnimationName、不回报（chip 保持底层动画）。返回是否成功。
   */
  function playTapMotion(slotIdx, animName) {
    var slot = slots[slotIdx];
    if (!slot.state || !slot.skeletonData) {
      return false;
    }
    var found = false;
    var anims = slot.skeletonData.animations || [];
    for (var i = 0; i < anims.length; i++) {
      if (anims[i].name === animName) {
        found = true;
        break;
      }
    }
    if (!found) {
      return false;
    }
    slot.tapReturnName = slot.playlist.enabled ? '' : slot.currentAnimationName;
    slot.tapAnimName = animName;
    try {
      slot.state.setAnimation(0, animName, false);
    } catch (e) {
      slot.tapAnimName = '';
      slot.tapReturnName = '';
      notifyError(slotIdx, 'ANIMATION_ERROR', (e && e.message) || e);
      return false;
    }
    renderFrame(0);
    return true;
  }

  // ==================== 渲染循环 ====================

  function cssSize() {
    return {
      w: canvas.clientWidth || window.innerWidth,
      h: canvas.clientHeight || window.innerHeight
    };
  }

  function resizeIfNeeded() {
    var dpr = Math.min(window.devicePixelRatio || 1, 2);
    var size = cssSize();
    var targetW = Math.round(size.w * dpr);
    var targetH = Math.round(size.h * dpr);
    if (canvas.width !== targetW || canvas.height !== targetH) {
      canvas.width = targetW;
      canvas.height = targetH;
    }
  }

  function applySkeletonTransform(slotIdx) {
    var slot = slots[slotIdx];
    var skel = slot.skeleton;
    if (!skel) {
      return;
    }
    var size = cssSize();
    var t = slot.transform;
    var safeScale = t.scale > 0.001 ? t.scale : 1.0;
    skel.x = size.w / 2 + t.x * size.w;
    skel.y = size.h / 2 + t.y * size.h;
    // 水平镜像：scaleX 取反（骨架默认朝向为正），镜像态在手势/重置后经此函数恒定恢复
    skel.scaleX = slot.mirrored ? -safeScale : safeScale;
    skel.scaleY = safeScale;
  }

  function renderFrame(deltaSeconds) {
    if (!gl) {
      return;
    }
    diag.drawn++;
    resizeIfNeeded();
    var size = cssSize();
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.clearColor(bgColor[0], bgColor[1], bgColor[2], bgColor[3]);
    gl.clear(gl.COLOR_BUFFER_BIT);
    // 自定义背景图先画（覆盖纯色，模型后画在其上）
    drawBackground(size);
    // slot1 先画（后层），slot0 后画（前层），与 Android 版层级一致
    var order = [1, 0];
    var active = null;
    for (var k = 0; k < order.length; k++) {
      var idx = order[k];
      var slot = slots[idx];
      if (!slot.skeleton) {
        continue;
      }
      // 隐藏槽整体跳过（动画 state 暂停，重新显示后从暂停处继续）
      if (!slot.visible) {
        continue;
      }
      var r = rendererFor(slot.version);
      if (!r) {
        continue;
      }
      // 版本切换时严格配对 begin/end，避免 GL 批次状态泄漏
      if (r !== active) {
        if (active) {
          active.end();
        }
        r.begin();
        active = r;
      }
      var cam = r.camera;
      cam.position.set(size.w / 2, size.h / 2, 0);
      cam.viewportWidth = size.w;
      cam.viewportHeight = size.h;
      if (slot.state && !slot.animationError) {
        try {
          if (slot.version === '4.2' && slot.skeleton.update) {
            slot.skeleton.update(deltaSeconds); // 4.2 物理约束时间步
          }
          slot.state.update(deltaSeconds);
          slot.state.apply(slot.skeleton);
        } catch (e) {
          // 动画数据损坏：停用 AnimationState，静态兜底（蓝本行为）
          slot.animationError = true;
          slot.state = null;
          slot.skeleton.setToSetupPose();
          notifyError(idx, 'ANIMATION_ERROR', (e && e.message) || e);
        }
      }
      applySkeletonTransform(idx);
      // 整体透明度：每帧幂等应用（加载后新骨架默认 1，命令早到/后到均覆盖）
      slot.skeleton.color.a = slot.alpha;
      if (slot.version === '4.2' && slot.rt) {
        // 4.2 运行时必须显式指定物理模式，无参会抛错
        slot.skeleton.updateWorldTransform(slot.rt.Physics.update);
      } else {
        slot.skeleton.updateWorldTransform();
      }
      r.drawSkeleton(slot.skeleton, slot.pma);
    }
    if (active) {
      active.end();
    }
  }

  function tick(now) {
    window.requestAnimationFrame(tick);
    diag.raf++;
    if (diag.last === 0) {
      diag.last = now;
    } else if (now - diag.last >= 2000) {
      console.log('[spine] diag raf=' + diag.raf + ' drawn=' + diag.drawn + ' playing=' + playing +
        ' fps=' + fps + ' dt=' + diag.dt.toFixed(3) +
        ' s0=' + slots[0].status + '/' + (slots[0].currentAnimationName || '-') +
        (slots[0].state ? '/st' : '/nost'));
      diag.raf = 0;
      diag.drawn = 0;
      diag.last = now;
    }
    var minInterval = 1000 / fps;
    if (now - lastFrameTime < minInterval - 1) {
      return;
    }
    var delta = lastFrameTime > 0 ? (now - lastFrameTime) / 1000 : 1 / 60;
    delta = Math.min(delta, 0.25); // 后台切回时避免大步长跳变
    lastFrameTime = now;
    diag.dt = delta;
    if (!playing) {
      return;
    }
    renderFrame(delta);
  }

  // ==================== 手势（拖拽 / 捏合 / 点按切动画） ====================

  var gesture = {
    mode: null, // 'drag' | 'pinch' | null
    startTouches: [], // [{x, y}]
    // 群组手势基线：参与手势的可见槽位列表 [{idx, scale, x, y}]
    // （整体模式：一指拖动/双指捏合同时作用于全部可见模型，隐藏槽零交互）
    startTransforms: [],
    startDistance: 0,
    moved: false,
    downTime: 0
  };

  function touchPoints(touches) {
    var points = [];
    for (var i = 0; i < touches.length; i++) {
      points.push({ x: touches[i].clientX, y: touches[i].clientY });
    }
    return points;
  }

  function distance(a, b) {
    var dx = a.x - b.x;
    var dy = a.y - b.y;
    return Math.sqrt(dx * dx + dy * dy);
  }

  /** 收集参与群组手势的槽位（已加载且可见），冻结各自变换基线。 */
  function visibleTransforms() {
    var list = [];
    for (var i = 0; i < slots.length; i++) {
      var s = slots[i];
      if (s.skeleton && s.visible) {
        list.push({ idx: i, scale: s.transform.scale, x: s.transform.x, y: s.transform.y });
      }
    }
    return list;
  }

  function onGestureEnd() {
    // 逐槽持久化：群组手势结束时每个参与的可见槽各发一条 onTransformChanged
    for (var k = 0; k < gesture.startTransforms.length; k++) {
      var t = gesture.startTransforms[k];
      var slot = slots[t.idx];
      if (!slot.skeleton) {
        continue;
      }
      bridgeCall('onTransformChanged', JSON.stringify({
        slot: t.idx,
        scale: slot.transform.scale,
        x: slot.transform.x,
        y: slot.transform.y
      }));
    }
  }

  function handleTap() {
    var slot = slots[gestureSlot];
    if (!slot.skeletonData || slot.status !== 'loaded' || !slot.visible) {
      return;
    }
    // 1. config.json tap_motions：命中 bounding box → 播放指定反应动画（播完自动恢复）
    if (slot.tapMotions.length > 0) {
      var tapPoint = gesture.startTouches.length > 0 ? gesture.startTouches[0] : { x: 0, y: 0 };
      var tapAnim = findTapMotionAt(gestureSlot, tapPoint);
      if (tapAnim && playTapMotion(gestureSlot, tapAnim)) {
        return;
      }
    }
    if (!tapSwitch) {
      return;
    }
    // 2. 轮播列表启用：点按 = 播下一个轮播项
    if (slot.playlist.enabled && slot.playlist.names.length > 0 && slot.state) {
      playPlaylistItem(gestureSlot, slot.playlist.index + 1, true);
      return;
    }
    // 3. 旧逻辑：全动画轮换
    var anims = slot.skeletonData.animations || [];
    if (!anims.length) {
      return;
    }
    var next = anims[0].name;
    if (slot.currentAnimationName) {
      var found = -1;
      for (var i = 0; i < anims.length; i++) {
        if (anims[i].name === slot.currentAnimationName) {
          found = i;
          break;
        }
      }
      if (found >= 0) {
        next = anims[(found + 1) % anims.length].name;
      }
    }
    slot.desired.animation = next;
    slot.desired.loop = true;
    playAnimationInternal(gestureSlot, next, true, true);
    bridgeCall('onAnimationChanged', JSON.stringify({
      slot: gestureSlot,
      name: next
    }));
    renderFrame(0);
  }

  canvas.addEventListener('touchstart', function (e) {
    e.preventDefault();
    // 任意画布触摸（点按/拖拽/捏合）即刻收起悬浮控制条
    bridgeCall('onScreenTap', '{}');
    var points = touchPoints(e.touches);
    if (points.length === 1) {
      gesture.mode = 'drag';
      gesture.startTouches = points;
      gesture.startTransforms = visibleTransforms();
      gesture.moved = false;
      gesture.downTime = Date.now();
    } else if (points.length >= 2) {
      gesture.mode = 'pinch';
      gesture.startTouches = points.slice(0, 2);
      gesture.startDistance = distance(points[0], points[1]);
      gesture.startTransforms = visibleTransforms();
      gesture.moved = true; // 双指不算 tap
    }
  }, { passive: false });

  canvas.addEventListener('touchmove', function (e) {
    e.preventDefault();
    var points = touchPoints(e.touches);
    var size = cssSize();
    if (gesture.mode === 'drag' && points.length >= 1 && gesture.startTransforms.length > 0) {
      var dx = points[0].x - gesture.startTouches[0].x;
      var dy = points[0].y - gesture.startTouches[0].y;
      if (Math.abs(dx) > TAP_SLOP_PX || Math.abs(dy) > TAP_SLOP_PX) {
        gesture.moved = true;
      }
      // 整体拖动：全部参与槽位应用同一位移（隐藏槽零交互）
      for (var k = 0; k < gesture.startTransforms.length; k++) {
        var t = gesture.startTransforms[k];
        var slot = slots[t.idx];
        if (!slot.visible) {
          continue; // 手势中途被隐藏的槽不再移动
        }
        slot.transform.x = t.x + dx / size.w;
        slot.transform.y = t.y - dy / size.h; // 屏幕 y 向下，世界 y 向上
      }
      renderFrame(0);
    } else if (gesture.mode === 'pinch' && points.length >= 2 && gesture.startDistance > 0 &&
      gesture.startTransforms.length > 0) {
      var dist = distance(points[0], points[1]);
      var factor = dist / gesture.startDistance;
      // 整体缩放：全部参与槽位应用同一缩放系数
      for (var j = 0; j < gesture.startTransforms.length; j++) {
        var tj = gesture.startTransforms[j];
        var s = slots[tj.idx];
        if (!s.visible) {
          continue;
        }
        var next = tj.scale * factor;
        s.transform.scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, next));
      }
      renderFrame(0);
    }
  }, { passive: false });

  canvas.addEventListener('touchend', function (e) {
    e.preventDefault();
    var remaining = e.touches.length;
    if (remaining === 0) {
      var quick = Date.now() - gesture.downTime <= TAP_TIMEOUT_MS;
      if (!gesture.moved && quick && gesture.mode === 'drag') {
        // 点按隐藏控制条的上报已在 touchstart 统一处理（任意触摸即刻收起）
        handleTap();
      } else if (gesture.moved) {
        onGestureEnd();
      }
      gesture.mode = null;
      gesture.moved = false;
    } else if (remaining === 1 && gesture.mode === 'pinch') {
      // 双指变单指：重置拖拽基准，避免跳变
      gesture.mode = 'drag';
      gesture.startTouches = touchPoints(e.touches);
      gesture.startTransforms = visibleTransforms();
    }
  }, { passive: false });

  canvas.addEventListener('touchcancel', function () {
    if (gesture.moved) {
      onGestureEnd();
    }
    gesture.mode = null;
    gesture.moved = false;
  }, { passive: false });

  // ==================== 工具函数 ====================

  function clampSlot(slot) {
    var value = Number(slot);
    if (!isFinite(value)) {
      return 0;
    }
    value = Math.round(value);
    if (value < 0) {
      return 0;
    }
    if (value > 1) {
      return 1;
    }
    return value;
  }

  function num(value, fallback) {
    var n = Number(value);
    return isFinite(n) ? n : fallback;
  }

  function parseColor(colorStr) {
    var s = String(colorStr).trim();
    if (s.charAt(0) === '#') {
      s = s.substring(1);
    }
    if (s.length === 6 && /^[0-9a-fA-F]{6}$/.test(s)) {
      var r = parseInt(s.substring(0, 2), 16) / 255;
      var g = parseInt(s.substring(2, 4), 16) / 255;
      var b = parseInt(s.substring(4, 6), 16) / 255;
      return [r, g, b, 1.0];
    }
    return null;
  }

  // ==================== 命令分发 ====================

  var commands = {
    loadModel: cmdLoadModel,
    playAnimation: cmdPlayAnimation,
    setSkins: cmdSetSkins,
    setTransform: cmdSetTransform,
    setPma: cmdSetPma,
    setPlaying: cmdSetPlaying,
    setTapSwitch: cmdSetTapSwitch,
    setFps: cmdSetFps,
    setBackgroundColor: cmdSetBackgroundColor,
    setBackgroundImage: cmdSetBackgroundImage,
    captureFrame: cmdCaptureFrame,
    clearSlot: cmdClearSlot,
    setGestureSlot: cmdSetGestureSlot,
    setSlotVisible: cmdSetSlotVisible,
        setMirror: cmdSetMirror,
        setAlpha: cmdSetAlpha,
        setSpeed: cmdSetSpeed,
        setMix: cmdSetMix,
        setPlaylist: cmdSetPlaylist
  };

  window.SpineHost = {
    cmd: function (msg) {
      try {
        if (!msg || typeof msg.cmd !== 'string') {
          notifyError(0, 'CMD_ERROR', '非法命令: ' + JSON.stringify(msg));
          return;
        }
        var handler = commands[msg.cmd];
        if (!handler) {
          notifyError(0, 'CMD_ERROR', '未知命令: ' + msg.cmd);
          return;
        }
        handler(msg);
      } catch (e) {
        notifyError(0, 'CMD_ERROR', (e && e.message) || e);
      }
    }
  };

  // ==================== 初始化 ====================

  function init() {
    var contextOptions = { alpha: true, antialias: true };
    try {
      console.log('[SpineHost] diag UA: ' + navigator.userAgent);
      console.log('[SpineHost] diag WebAssembly: ' + typeof WebAssembly);
      var p1 = document.createElement('canvas');
      var g2 = p1.getContext('webgl2', contextOptions);
      console.log('[SpineHost] diag fresh webgl2: ' + (g2 ? (g2.getParameter(g2.VERSION) + ' | ' + g2.getParameter(g2.RENDERER)) : 'null'));
      var p2 = document.createElement('canvas');
      var g1 = p2.getContext('webgl', contextOptions);
      console.log('[SpineHost] diag fresh webgl(aa): ' + (g1 ? (g1.getParameter(g1.VERSION) + ' | ' + g1.getParameter(g1.RENDERER)) : 'null'));
      var p3 = document.createElement('canvas');
      console.log('[SpineHost] diag fresh webgl(noopts): ' + (p3.getContext('webgl') ? 'ok' : 'null'));
      var p4 = document.createElement('canvas');
      console.log('[SpineHost] diag fresh experimental-webgl: ' + (p4.getContext('experimental-webgl', contextOptions) ? 'ok' : 'null'));
      var p5 = document.createElement('canvas');
      console.log('[SpineHost] diag fresh 2d: ' + (p5.getContext('2d') ? 'ok' : 'null'));
    } catch (e) {
      console.log('[SpineHost] diag error: ' + ((e && e.message) || e));
    }
    gl = canvas.getContext('webgl', contextOptions) || canvas.getContext('experimental-webgl', contextOptions);
    if (!gl) {
      console.error('[SpineHost] WebGL context creation failed (webgl & experimental-webgl both null)');
      notifyError(0, 'NO_WEBGL', '当前环境不支持 WebGL，请尝试真机设备运行');
      return;
    }
    console.log('[SpineHost] WebGL context ready: ' + gl.getParameter(gl.VERSION) + ' | ' + gl.getParameter(gl.RENDERER));
    resizeIfNeeded();
    window.addEventListener('resize', function () {
      renderFrame(0);
    });
    window.requestAnimationFrame(tick);
  }

  // per-version SceneRenderer：多运行时版本共存，各版本惰性创建，避免命名空间互相覆盖
  function rendererFor(versionKey) {
    if (!gl || !versionKey) {
      return null;
    }
    if (!renderers[versionKey]) {
      var rt = runtimeCache[versionKey];
      if (!rt) {
        return null;
      }
      renderers[versionKey] = new rt.SceneRenderer(canvas, gl, true);
      console.log('[spine] renderer created for ' + versionKey);
    }
    return renderers[versionKey];
  }

  init();
})();
