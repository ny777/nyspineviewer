/**
 * Spine 播放宿主（ArkWeb ↔ spine-ts 多版本运行时 4.0 / 4.1 / 4.2）。
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
 *              onCaptureFrame / onTransformChanged / onAnimationChanged
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

  var canvas = document.getElementById('spine-canvas');
  var gl = null;
  var renderers = {}; // versionKey -> SceneRenderer（多版本共存，各自惰性创建）
  var runtimeCache = {}; // version -> spine namespace
  var playing = true;
  var fps = 60;
  var lastFrameTime = 0;
  var bgColor = [0.059, 0.090, 0.165, 1.0]; // #0F172A
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

  // ==================== 运行时加载（版本分发器，支持 4.0 / 4.1 / 4.2） ====================

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

  // ==================== 命令处理 ====================

  function cmdLoadModel(msg) {
    var slotIdx = clampSlot(msg.slot);
    var slot = slots[slotIdx];
    disposeSlot(slotIdx);
    slot.reset();
    slot.status = 'loading';
    slot.modelId = String(msg.modelId || '');
    slot.version = String(msg.version || '4.1');
    slot.skelFile = String(msg.skelFile || '');
    slot.atlasFile = String(msg.atlasFile || '');
    slot.pma = !!msg.pma;

    if (!slot.modelId || !slot.skelFile || !slot.atlasFile) {
      slot.status = 'error';
      notifyError(slotIdx, 'LOAD_FAILED', 'loadModel 缺少 modelId/skelFile/atlasFile');
      return;
    }

    ensureRuntime(slot.version).then(function (spine) {
      return fetchText(modelUrl(slot.modelId, slot.atlasFile)).then(function (atlasText) {
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
            return jsonReader.readSkeletonData(text);
          });
        }
        return fetchArrayBuffer(modelUrl(slot.modelId, slot.skelFile)).then(function (buf) {
          var binaryReader = new spine.SkeletonBinary(attachmentLoader);
          return binaryReader.readSkeletonData(new Uint8Array(buf));
        });
      }).then(function (skeletonData) {
        var spine = runtimeCache[slot.version];
        slot.rt = spine; // 供渲染循环做版本分支（如 4.2 Physics）
        var skeleton = new spine.Skeleton(skeletonData);
        var stateData = new spine.AnimationStateData(skeletonData);
        stateData.defaultMix = 0.2; // 4.1 行为蓝本
        var animState = new spine.AnimationState(stateData);
        slot.skeletonData = skeletonData;
        slot.skeleton = skeleton;
        slot.state = animState;
        slot.status = 'loaded';
        slot.animationError = false;
        console.log('[spine] modelLoaded slot=' + slotIdx + ' anims=' +
          (skeletonData.animations ? skeletonData.animations.length : 0) +
          ' skins=' + (skeletonData.skins ? skeletonData.skins.length : 0));
        applyDesired(slotIdx);
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

  function cmdSetGestureSlot(msg) {
    gestureSlot = clampSlot(msg.slot);
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
    skel.scaleX = safeScale;
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
    // slot1 先画（后层），slot0 后画（前层），与 Android 版层级一致
    var order = [1, 0];
    var active = null;
    for (var k = 0; k < order.length; k++) {
      var idx = order[k];
      var slot = slots[idx];
      if (!slot.skeleton) {
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
    startTransform: null,
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

  function onGestureEnd() {
    var slot = slots[gestureSlot];
    if (!slot.skeleton) {
      return;
    }
    bridgeCall('onTransformChanged', JSON.stringify({
      slot: gestureSlot,
      scale: slot.transform.scale,
      x: slot.transform.x,
      y: slot.transform.y
    }));
  }

  function handleTap() {
    var slot = slots[gestureSlot];
    if (!slot.skeletonData || slot.status !== 'loaded') {
      return;
    }
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
    var points = touchPoints(e.touches);
    var slot = slots[gestureSlot];
    if (points.length === 1) {
      gesture.mode = 'drag';
      gesture.startTouches = points;
      gesture.startTransform = {
        scale: slot.transform.scale,
        x: slot.transform.x,
        y: slot.transform.y
      };
      gesture.moved = false;
      gesture.downTime = Date.now();
    } else if (points.length >= 2) {
      gesture.mode = 'pinch';
      gesture.startTouches = points.slice(0, 2);
      gesture.startDistance = distance(points[0], points[1]);
      gesture.startTransform = {
        scale: slot.transform.scale,
        x: slot.transform.x,
        y: slot.transform.y
      };
      gesture.moved = true; // 双指不算 tap
    }
  }, { passive: false });

  canvas.addEventListener('touchmove', function (e) {
    e.preventDefault();
    var points = touchPoints(e.touches);
    var slot = slots[gestureSlot];
    if (!slot.skeleton) {
      return;
    }
    var size = cssSize();
    if (gesture.mode === 'drag' && points.length >= 1 && gesture.startTransform) {
      var dx = points[0].x - gesture.startTouches[0].x;
      var dy = points[0].y - gesture.startTouches[0].y;
      if (Math.abs(dx) > TAP_SLOP_PX || Math.abs(dy) > TAP_SLOP_PX) {
        gesture.moved = true;
      }
      slot.transform.x = gesture.startTransform.x + dx / size.w;
      slot.transform.y = gesture.startTransform.y - dy / size.h; // 屏幕 y 向下，世界 y 向上
      renderFrame(0);
    } else if (gesture.mode === 'pinch' && points.length >= 2 && gesture.startDistance > 0) {
      var dist = distance(points[0], points[1]);
      var factor = dist / gesture.startDistance;
      var next = gesture.startTransform.scale * factor;
      next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, next));
      slot.transform.scale = next;
      renderFrame(0);
    }
  }, { passive: false });

  canvas.addEventListener('touchend', function (e) {
    e.preventDefault();
    var remaining = e.touches.length;
    if (remaining === 0) {
      var quick = Date.now() - gesture.downTime <= TAP_TIMEOUT_MS;
      if (!gesture.moved && quick && gesture.mode === 'drag') {
        handleTap();
      } else if (gesture.moved) {
        onGestureEnd();
      }
      gesture.mode = null;
      gesture.moved = false;
    } else if (remaining === 1 && gesture.mode === 'pinch') {
      // 双指变单指：重置拖拽基准，避免跳变
      gesture.mode = 'drag';
      var slot = slots[gestureSlot];
      gesture.startTouches = touchPoints(e.touches);
      gesture.startTransform = {
        scale: slot.transform.scale,
        x: slot.transform.x,
        y: slot.transform.y
      };
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
    setFps: cmdSetFps,
    setBackgroundColor: cmdSetBackgroundColor,
    captureFrame: cmdCaptureFrame,
    clearSlot: cmdClearSlot,
    setGestureSlot: cmdSetGestureSlot
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
