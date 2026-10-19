/**
 * 二进制 .skel 离线预读取器（A3）：
 * 按 spine-{4.0,4.1,4.2}.js 运行时的字节规格逐段消费，导入时即可获得真实动画/皮肤名。
 * 任何异常/门禁不满足 → null → 调用方回退占位名（fail-safe，导入永不因此失败）。
 * 规格已对照 runtimes 源码逐行核实：readSkeletonData / readSkin / readAttachment /
 * readVertices / readSequence / readAnimation / readTimeline1/2 / setBezier（恒 4 float）。
 */
import { fileIo } from '@kit.CoreFileKit';

const TAG = 'SpineBinaryPeeker';
/** 循环计数上限（防垃圾数据死循环，EOF 守卫兜底）。 */
const MAX_LOOP_COUNT = 1000000;
/** 单文件预读取体积上限（64MB）。 */
const MAX_SKEL_BYTES = 67108864;

/** 预读取结果。 */
export class SpinePeekResult {
  /** 骨架头部 version 串（如 '4.2.38'）。 */
  version: string = '';
  animations: Array<string> = new Array<string>();
  /** 含 'default'（若默认皮肤存在）。 */
  skins: Array<string> = new Array<string>();
}

/** 大端字节读取器（三版本一致，DataView 不传 littleEndian）。 */
class SkelByteReader {
  private bytes: Uint8Array;
  private view: DataView;
  private idx: number = 0;
  /** 字符串表（readStringRef 用）。 */
  strings: Array<string> = new Array<string>();

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }

  get offset(): number {
    return this.idx;
  }

  get length(): number {
    return this.bytes.length;
  }

  private ensure(n: number): void {
    if (this.idx + n > this.view.byteLength) {
      throw new Error('skel eof');
    }
  }

  readByte(): number {
    this.ensure(1);
    const v = this.view.getInt8(this.idx);
    this.idx += 1;
    return v;
  }

  readUnsignedByte(): number {
    this.ensure(1);
    const v = this.view.getUint8(this.idx);
    this.idx += 1;
    return v;
  }

  readShort(): number {
    this.ensure(2);
    const v = this.view.getInt16(this.idx);
    this.idx += 2;
    return v;
  }

  readInt32(): number {
    this.ensure(4);
    const v = this.view.getInt32(this.idx);
    this.idx += 4;
    return v;
  }

  readFloat(): number {
    this.ensure(4);
    const v = this.view.getFloat32(this.idx);
    this.idx += 4;
    return v;
  }

  readBoolean(): boolean {
    return this.readByte() !== 0;
  }

  /** varint（1..5 字节）；optimizePositive=false 时 zigzag 解码。 */
  readInt(optimizePositive: boolean): number {
    let b = this.readByte();
    let result = b & 127;
    if ((b & 128) !== 0) {
      b = this.readByte();
      result |= (b & 127) << 7;
      if ((b & 128) !== 0) {
        b = this.readByte();
        result |= (b & 127) << 14;
        if ((b & 128) !== 0) {
          b = this.readByte();
          result |= (b & 127) << 21;
          if ((b & 128) !== 0) {
            b = this.readByte();
            result |= (b & 127) << 28;
          }
        }
      }
    }
    return optimizePositive ? result : ((result >>> 1) ^ (-(result & 1)));
  }

  /** 作为循环次数使用的 readInt(true)，带上限守卫。 */
  readCount(): number {
    const n = this.readInt(true);
    if (n < 0 || n > MAX_LOOP_COUNT) {
      throw new Error('skel count');
    }
    return n;
  }

  /** 哨兵：0→null，1→''；随后 byteCount-1 字节手写 UTF-8 解码（2/3 字节序列）。
   * null 与 '' 均归并为 ''（运行时对相关字符串仅做真值判断，字节流语义等价）。 */
  readString(): string {
    let n = this.readInt(true);
    if (n === 0 || n === 1) {
      return '';
    }
    n -= 1;
    this.ensure(n);
    let out = '';
    for (let i = 0; i < n; i++) {
      const b = this.readUnsignedByte();
      if ((b & 0xF0) === 0xC0 || (b & 0xF0) === 0xD0) {
        const b2 = this.readByte();
        out += String.fromCharCode(((b & 0x1F) << 6) | (b2 & 0x3F));
      } else if ((b & 0xF0) === 0xE0) {
        const b2 = this.readByte();
        const b3 = this.readByte();
        out += String.fromCharCode(((b & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F));
      } else {
        out += String.fromCharCode(b);
      }
    }
    return out;
  }

  readStringRef(): string {
    const index = this.readInt(true);
    if (index === 0) {
      return '';
    }
    const i = index - 1;
    if (i >= 0 && i < this.strings.length) {
      return this.strings[i];
    }
    throw new Error('skel string ref');
  }
}

/** 骨架数据遍历器（按版本分支消费字节，收集 version/animations/skins）。 */
class SkelPeekWalker {
  private r: SkelByteReader;
  private is40: boolean;
  private is42: boolean;
  private nonessential: boolean = false;
  headerVersion: string = '';
  animations: Array<string> = new Array<string>();
  skins: Array<string> = new Array<string>();

  constructor(reader: SkelByteReader, version: string) {
    this.r = reader;
    this.is40 = version === '4.0';
    this.is42 = version === '4.2';
  }

  walk(): void {
    const r = this.r;
    // 头部
    r.readInt32();
    r.readInt32();
    this.headerVersion = r.readString();
    r.readFloat();
    r.readFloat();
    r.readFloat();
    r.readFloat();
    if (this.is42) {
      r.readFloat();
    }
    this.nonessential = r.readBoolean();
    if (this.nonessential) {
      r.readFloat();
      r.readString();
      r.readString();
    }
    // 字符串表
    const strCount = r.readCount();
    for (let i = 0; i < strCount; i++) {
      r.strings.push(r.readString());
    }
    // 骨骼
    const boneCount = r.readCount();
    for (let i = 0; i < boneCount; i++) {
      r.readString();
      if (i > 0) {
        r.readInt(true);
      }
      let k = 0;
      while (k < 8) {
        r.readFloat();
        k++;
      }
      if (this.is42) {
        r.readByte();
      } else {
        r.readInt(true);
      }
      r.readBoolean();
      if (this.nonessential) {
        r.readInt32();
        if (this.is42) {
          r.readString();
          r.readBoolean();
        }
      }
    }
    // 槽位
    const slotCount = r.readCount();
    for (let i = 0; i < slotCount; i++) {
      r.readString();
      r.readInt(true);
      r.readInt32();
      r.readInt32();
      r.readStringRef();
      r.readInt(true);
      if (this.is42 && this.nonessential) {
        r.readBoolean();
      }
    }
    // IK 约束
    const ikCount = r.readCount();
    for (let i = 0; i < ikCount; i++) {
      r.readString();
      r.readInt(true);
      if (!this.is42) {
        r.readBoolean();
      }
      const nb = r.readCount();
      for (let j = 0; j < nb; j++) {
        r.readInt(true);
      }
      r.readInt(true);
      if (!this.is42) {
        r.readFloat();
        r.readFloat();
        r.readByte();
        r.readBoolean();
        r.readBoolean();
        r.readBoolean();
      } else {
        const flags = r.readByte();
        if ((flags & 32) !== 0 && (flags & 64) !== 0) {
          r.readFloat();
        }
        if ((flags & 128) !== 0) {
          r.readFloat();
        }
      }
    }
    // Transform 约束
    const tfCount = r.readCount();
    for (let i = 0; i < tfCount; i++) {
      r.readString();
      r.readInt(true);
      if (!this.is42) {
        r.readBoolean();
      }
      const nb = r.readCount();
      for (let j = 0; j < nb; j++) {
        r.readInt(true);
      }
      r.readInt(true);
      if (!this.is42) {
        r.readBoolean();
        r.readBoolean();
        let k = 0;
        while (k < 12) {
          r.readFloat();
          k++;
        }
      } else {
        const f1 = r.readByte();
        if ((f1 & 8) !== 0) {
          r.readFloat();
        }
        if ((f1 & 16) !== 0) {
          r.readFloat();
        }
        if ((f1 & 32) !== 0) {
          r.readFloat();
        }
        if ((f1 & 64) !== 0) {
          r.readFloat();
        }
        if ((f1 & 128) !== 0) {
          r.readFloat();
        }
        const f2 = r.readByte();
        let mask = 1;
        while (mask <= 64) {
          if ((f2 & mask) !== 0) {
            r.readFloat();
          }
          mask <<= 1;
        }
      }
    }
    // Path 约束
    const pathCount = r.readCount();
    for (let i = 0; i < pathCount; i++) {
      r.readString();
      r.readInt(true);
      r.readBoolean();
      const nb = r.readCount();
      for (let j = 0; j < nb; j++) {
        r.readInt(true);
      }
      r.readInt(true);
      if (!this.is42) {
        r.readInt(true);
        r.readInt(true);
        r.readInt(true);
        r.readFloat();
        r.readFloat();
        r.readFloat();
        r.readFloat();
        r.readFloat();
        r.readFloat();
      } else {
        const flags = r.readByte();
        if ((flags & 128) !== 0) {
          r.readFloat();
        }
        r.readFloat();
        r.readFloat();
        r.readFloat();
        r.readFloat();
        r.readFloat();
      }
    }
    // Physics 约束（仅 4.2）
    if (this.is42) {
      const phCount = r.readCount();
      for (let i = 0; i < phCount; i++) {
        r.readString();
        r.readInt(true);
        r.readInt(true);
        const flags = r.readByte();
        let mask = 2;
        while (mask <= 64) {
          if ((flags & mask) !== 0) {
            r.readFloat();
          }
          mask <<= 1;
        }
        r.readUnsignedByte();
        r.readFloat();
        r.readFloat();
        r.readFloat();
        if ((flags & 128) !== 0) {
          r.readFloat();
        }
        r.readFloat();
        r.readFloat();
        const flags2 = r.readByte();
        if ((flags2 & 128) !== 0) {
          r.readFloat();
        }
      }
    }
    // 皮肤
    if (this.readSkin(true)) {
      this.skins.push('default');
    }
    const skinCount = r.readCount();
    for (let i = 0; i < skinCount; i++) {
      this.readSkin(false);
    }
    // 事件数据（记录 audioPath 供事件时间轴消费判断）
    const eventCount = r.readCount();
    const eventHasAudio: Array<boolean> = new Array<boolean>();
    for (let i = 0; i < eventCount; i++) {
      if (this.is42) {
        r.readString();
      } else {
        r.readStringRef();
      }
      r.readInt(false);
      r.readFloat();
      r.readString();
      const audioPath = r.readString();
      const hasAudio = audioPath !== '';
      eventHasAudio.push(hasAudio);
      if (hasAudio) {
        r.readFloat();
        r.readFloat();
      }
    }
    // 动画
    const animCount = r.readCount();
    for (let i = 0; i < animCount; i++) {
      this.animations.push(r.readString());
      this.readAnimation(eventHasAudio);
    }
  }

  /** 读取一个皮肤；返回是否存在。defaultSkin=true 时 slotCount 为 0 表示无默认皮肤。 */
  private readSkin(defaultSkin: boolean): boolean {
    const r = this.r;
    let slotCount = 0;
    if (defaultSkin) {
      slotCount = r.readCount();
      if (slotCount === 0) {
        return false;
      }
    } else {
      if (this.is42) {
        this.skins.push(r.readString());
        if (this.nonessential) {
          r.readInt32();
        }
      } else {
        this.skins.push(r.readStringRef());
      }
      const boneN = r.readCount();
      for (let i = 0; i < boneN; i++) {
        r.readInt(true);
      }
      const ikN = r.readCount();
      for (let i = 0; i < ikN; i++) {
        r.readInt(true);
      }
      const tfN = r.readCount();
      for (let i = 0; i < tfN; i++) {
        r.readInt(true);
      }
      const pathN = r.readCount();
      for (let i = 0; i < pathN; i++) {
        r.readInt(true);
      }
      if (this.is42) {
        const phN = r.readCount();
        for (let i = 0; i < phN; i++) {
          r.readInt(true);
        }
      }
      slotCount = r.readCount();
    }
    for (let i = 0; i < slotCount; i++) {
      r.readInt(true);
      const nn = r.readCount();
      for (let j = 0; j < nn; j++) {
        r.readStringRef();
        this.readAttachment();
      }
    }
    return true;
  }

  private readAttachment(): void {
    const r = this.r;
    if (!this.is42) {
      this.readAttachment41();
      return;
    }
    // 4.2：flags 字节在前，name 视 flags&8 读取
    const flags = r.readByte();
    const type = flags & 7;
    if ((flags & 8) !== 0) {
      r.readStringRef();
    }
    if (type === 0) {
      if ((flags & 16) !== 0) {
        r.readStringRef();
      }
      if ((flags & 32) !== 0) {
        r.readInt32();
      }
      if ((flags & 64) !== 0) {
        this.readSequence42();
      }
      if ((flags & 128) !== 0) {
        r.readFloat();
      }
      let k = 0;
      while (k < 6) {
        r.readFloat();
        k++;
      }
    } else if (type === 1) {
      this.readVertices42((flags & 16) !== 0);
      if (this.nonessential) {
        r.readInt32();
      }
    } else if (type === 2) {
      if ((flags & 16) !== 0) {
        r.readStringRef();
      }
      if ((flags & 32) !== 0) {
        r.readInt32();
      }
      if ((flags & 64) !== 0) {
        this.readSequence42();
      }
      // 4.2 顺序：hullLength/vertices 在 uvs/triangles 之前（与 4.0/4.1 相反）
      const hullLength = r.readInt(true);
      const vc = this.readVertices42((flags & 128) !== 0);
      this.readFloatArray(vc << 1);
      const triCount = (vc * 2 - hullLength - 2) * 3;
      if (triCount < 0) {
        throw new Error('skel mesh triangles');
      }
      for (let i = 0; i < triCount; i++) {
        r.readInt(true);
      }
      if (this.nonessential) {
        const edgeCount = r.readCount();
        for (let i = 0; i < edgeCount; i++) {
          r.readInt(true);
        }
        r.readFloat();
        r.readFloat();
      }
    } else if (type === 3) {
      if ((flags & 16) !== 0) {
        r.readStringRef();
      }
      if ((flags & 32) !== 0) {
        r.readInt32();
      }
      if ((flags & 64) !== 0) {
        this.readSequence42();
      }
      r.readInt(true);
      r.readStringRef();
      if (this.nonessential) {
        r.readFloat();
        r.readFloat();
      }
    } else if (type === 4) {
      const vc = this.readVertices42((flags & 64) !== 0);
      const segCount = Math.floor((vc * 2) / 6);
      for (let i = 0; i < segCount; i++) {
        r.readFloat();
      }
      if (this.nonessential) {
        r.readInt32();
      }
    } else if (type === 5) {
      r.readFloat();
      r.readFloat();
      r.readFloat();
      if (this.nonessential) {
        r.readInt32();
      }
    } else if (type === 6) {
      r.readInt(true);
      this.readVertices42((flags & 16) !== 0);
      if (this.nonessential) {
        r.readInt32();
      }
    } else {
      throw new Error('skel attachment type');
    }
  }

  /** 4.0/4.1：name=readStringRef，type=readByte。 */
  private readAttachment41(): void {
    const r = this.r;
    r.readStringRef();
    const type = r.readByte();
    if (type === 0) {
      r.readStringRef();
      let k = 0;
      while (k < 7) {
        r.readFloat();
        k++;
      }
      r.readInt32();
      if (!this.is40) {
        this.readSequence41();
      }
    } else if (type === 1) {
      const vc = r.readCount();
      this.readVertices41(vc);
      if (this.nonessential) {
        r.readInt32();
      }
    } else if (type === 2) {
      r.readStringRef();
      r.readInt32();
      const vc = r.readCount();
      this.readFloatArray(vc << 1);
      this.readShortArray01();
      this.readVertices41(vc);
      r.readInt(true);
      if (!this.is40) {
        this.readSequence41();
      }
      if (this.nonessential) {
        this.readShortArray01();
        r.readFloat();
        r.readFloat();
      }
    } else if (type === 3) {
      r.readStringRef();
      r.readInt32();
      r.readStringRef();
      r.readStringRef();
      r.readBoolean();
      if (!this.is40) {
        this.readSequence41();
      }
      if (this.nonessential) {
        r.readFloat();
        r.readFloat();
      }
    } else if (type === 4) {
      r.readBoolean();
      r.readBoolean();
      const vc = r.readCount();
      this.readVertices41(vc);
      const segCount = Math.floor(vc / 3);
      for (let i = 0; i < segCount; i++) {
        r.readFloat();
      }
      if (this.nonessential) {
        r.readInt32();
      }
    } else if (type === 5) {
      r.readFloat();
      r.readFloat();
      r.readFloat();
      if (this.nonessential) {
        r.readInt32();
      }
    } else if (type === 6) {
      r.readInt(true);
      const vc = r.readCount();
      this.readVertices41(vc);
      if (this.nonessential) {
        r.readInt32();
      }
    } else {
      throw new Error('skel attachment type');
    }
  }

  /** 4.0/4.1 顶点：weighted 布尔在内部读。 */
  private readVertices41(vertexCount: number): void {
    const r = this.r;
    const weighted = r.readBoolean();
    if (!weighted) {
      this.readFloatArray(vertexCount << 1);
      return;
    }
    for (let i = 0; i < vertexCount; i++) {
      const boneCount = r.readCount();
      for (let j = 0; j < boneCount; j++) {
        r.readInt(true);
        r.readFloat();
        r.readFloat();
        r.readFloat();
      }
    }
  }

  /** 4.2 顶点：vertexCount 在内部读；返回 vertexCount。 */
  private readVertices42(weighted: boolean): number {
    const r = this.r;
    const vertexCount = r.readCount();
    if (!weighted) {
      this.readFloatArray(vertexCount << 1);
      return vertexCount;
    }
    for (let i = 0; i < vertexCount; i++) {
      const boneCount = r.readCount();
      for (let j = 0; j < boneCount; j++) {
        r.readInt(true);
        r.readFloat();
        r.readFloat();
        r.readFloat();
      }
    }
    return vertexCount;
  }

  private readFloatArray(n: number): void {
    const r = this.r;
    for (let i = 0; i < n; i++) {
      r.readFloat();
    }
  }

  /** 4.0/4.1 短整型数组：前置 count + 真 int16（大端）。 */
  private readShortArray01(): void {
    const r = this.r;
    const n = r.readCount();
    for (let i = 0; i < n; i++) {
      r.readShort();
    }
  }

  /** 4.0/4.1 序列：布尔门禁 + 4 个 varint。 */
  private readSequence41(): void {
    const r = this.r;
    if (!r.readBoolean()) {
      return;
    }
    r.readInt(true);
    r.readInt(true);
    r.readInt(true);
    r.readInt(true);
  }

  /** 4.2 序列：无布尔，4 个 varint。 */
  private readSequence42(): void {
    const r = this.r;
    r.readInt(true);
    r.readInt(true);
    r.readInt(true);
    r.readInt(true);
  }

  private readAnimation(eventHasAudio: Array<boolean>): void {
    const r = this.r;
    r.readInt(true);
    // (a) 槽位时间轴
    const slotTimelineCount = r.readCount();
    for (let i = 0; i < slotTimelineCount; i++) {
      r.readInt(true);
      const nn = r.readCount();
      for (let j = 0; j < nn; j++) {
        const type = r.readByte();
        const frameCount = r.readCount();
        const frameLast = frameCount - 1;
        if (type === 0) {
          for (let f = 0; f < frameCount; f++) {
            r.readFloat();
            r.readStringRef();
          }
          continue;
        }
        r.readInt(true);
        let channels = 0;
        if (type === 1) {
          channels = 4;
        } else if (type === 2) {
          channels = 3;
        } else if (type === 3) {
          channels = 7;
        } else if (type === 4) {
          channels = 6;
        } else if (type === 5) {
          channels = 1;
        } else {
          throw new Error('skel slot timeline');
        }
        r.readFloat();
        this.readUnsignedBytes(channels);
        for (let f = 0; f < frameLast; f++) {
          r.readFloat();
          this.readUnsignedBytes(channels);
          if (r.readByte() === 2) {
            this.readBezierBlock(channels);
          }
        }
      }
    }
    // (b) 骨骼时间轴
    const boneTimelineCount = r.readCount();
    for (let i = 0; i < boneTimelineCount; i++) {
      r.readInt(true);
      const nn = r.readCount();
      for (let j = 0; j < nn; j++) {
        const type = r.readByte();
        const frameCount = r.readCount();
        if (this.is42 && type === 10) {
          for (let f = 0; f < frameCount; f++) {
            r.readFloat();
            r.readByte();
          }
          continue;
        }
        r.readInt(true);
        if (type === 1 || type === 4 || type === 7) {
          this.readTimeline2(frameCount);
        } else if (type <= 9) {
          this.readTimeline1(frameCount);
        }
      }
    }
    // (c) IK 时间轴
    const ikTimelineCount = r.readCount();
    for (let i = 0; i < ikTimelineCount; i++) {
      r.readInt(true);
      const frameCount = r.readCount();
      r.readInt(true);
      const frameLast = frameCount - 1;
      if (!this.is42) {
        r.readFloat();
        r.readFloat();
        r.readFloat();
        for (let f = 0; f < frameCount; f++) {
          r.readByte();
          r.readBoolean();
          r.readBoolean();
          if (f === frameLast) {
            break;
          }
          r.readFloat();
          r.readFloat();
          r.readFloat();
          if (r.readByte() === 2) {
            this.readBezierBlock(2);
          }
        }
      } else {
        let flags = r.readByte();
        r.readFloat();
        if ((flags & 1) !== 0 && (flags & 2) !== 0) {
          r.readFloat();
        }
        if ((flags & 4) !== 0) {
          r.readFloat();
        }
        for (let f = 0; f < frameCount; f++) {
          if (f === frameLast) {
            break;
          }
          flags = r.readByte();
          r.readFloat();
          if ((flags & 1) !== 0 && (flags & 2) !== 0) {
            r.readFloat();
          }
          if ((flags & 4) !== 0) {
            r.readFloat();
          }
          if ((flags & 64) === 0 && (flags & 128) !== 0) {
            this.readBezierBlock(2);
          }
        }
      }
    }
    // (d) Transform 时间轴
    const tfTimelineCount = r.readCount();
    for (let i = 0; i < tfTimelineCount; i++) {
      r.readInt(true);
      const frameCount = r.readCount();
      r.readInt(true);
      const frameLast = frameCount - 1;
      let k = 0;
      while (k < 7) {
        r.readFloat();
        k++;
      }
      for (let f = 0; f < frameCount; f++) {
        if (f === frameLast) {
          break;
        }
        let m = 0;
        while (m < 7) {
          r.readFloat();
          m++;
        }
        if (r.readByte() === 2) {
          this.readBezierBlock(6);
        }
      }
    }
    // (e) Path 时间轴
    const pathTimelineCount = r.readCount();
    for (let i = 0; i < pathTimelineCount; i++) {
      r.readInt(true);
      const nn = r.readCount();
      for (let j = 0; j < nn; j++) {
        const type = r.readByte();
        if (type === 0 || type === 1) {
          this.readTimeline1(r.readCount());
        } else if (type === 2) {
          const frameCount = r.readCount();
          r.readInt(true);
          const frameLast = frameCount - 1;
          let k = 0;
          while (k < 4) {
            r.readFloat();
            k++;
          }
          for (let f = 0; f < frameCount; f++) {
            if (f === frameLast) {
              break;
            }
            let m = 0;
            while (m < 4) {
              r.readFloat();
              m++;
            }
            if (r.readByte() === 2) {
              this.readBezierBlock(3);
            }
          }
        } else {
          throw new Error('skel path timeline');
        }
      }
    }
    // (f) Physics 时间轴（仅 4.2）
    if (this.is42) {
      const phTimelineCount = r.readCount();
      for (let i = 0; i < phTimelineCount; i++) {
        r.readInt(true);
        const nn = r.readCount();
        for (let j = 0; j < nn; j++) {
          const type = r.readByte();
          const frameCount = r.readCount();
          if (type === 8) {
            for (let f = 0; f < frameCount; f++) {
              r.readFloat();
            }
            continue;
          }
          r.readInt(true);
          if (type === 0 || type === 1 || type === 2 || (type >= 4 && type <= 7)) {
            this.readTimeline1(frameCount);
          }
        }
      }
    }
    // (g) 附件（deform/sequence）时间轴
    const defTimelineCount = r.readCount();
    for (let i = 0; i < defTimelineCount; i++) {
      r.readInt(true);
      const nn = r.readCount();
      for (let j = 0; j < nn; j++) {
        r.readInt(true);
        const nnn = r.readCount();
        for (let m = 0; m < nnn; m++) {
          r.readStringRef();
          if (this.is40) {
            const frameCount = r.readCount();
            r.readInt(true);
            r.readFloat();
            this.readDeformFrames(frameCount - 1);
          } else {
            const timelineType = r.readByte();
            const frameCount = r.readCount();
            if (timelineType === 0) {
              r.readInt(true);
              r.readFloat();
              this.readDeformFrames(frameCount - 1);
            } else if (timelineType === 1) {
              for (let f = 0; f < frameCount; f++) {
                r.readFloat();
                r.readInt32();
                r.readFloat();
              }
            } else {
              throw new Error('skel deform timeline');
            }
          }
        }
      }
    }
    // (h) 绘制顺序
    const drawOrderCount = r.readCount();
    for (let i = 0; i < drawOrderCount; i++) {
      r.readFloat();
      const offsetCount = r.readCount();
      for (let j = 0; j < offsetCount; j++) {
        r.readInt(true);
        r.readInt(true);
      }
    }
    // (i) 事件时间轴
    const eventTimelineCount = r.readCount();
    for (let i = 0; i < eventTimelineCount; i++) {
      r.readFloat();
      const eventIndex = r.readInt(true);
      r.readInt(false);
      r.readFloat();
      if (!this.is42) {
        if (r.readBoolean()) {
          r.readString();
        }
      } else {
        r.readString();
      }
      if (eventIndex >= 0 && eventIndex < eventHasAudio.length && eventHasAudio[eventIndex]) {
        r.readFloat();
        r.readFloat();
      }
    }
  }

  /** deform 帧循环：end==0 无附加字节；否则 start + end 个 float（end 为 +=start 前的值）。 */
  private readDeformFrames(frameLast: number): void {
    const r = this.r;
    for (let f = 0; ; f++) {
      const end = r.readInt(true);
      if (end !== 0) {
        r.readInt(true);
        if (end < 0) {
          throw new Error('skel deform');
        }
        this.readFloatArray(end);
      }
      if (f === frameLast) {
        break;
      }
      r.readFloat();
      if (r.readByte() === 2) {
        this.readBezierBlock(1);
      }
    }
  }

  private readTimeline1(frameCount: number): void {
    const r = this.r;
    const frameLast = frameCount - 1;
    r.readFloat();
    r.readFloat();
    for (let f = 0; f < frameCount; f++) {
      if (f === frameLast) {
        break;
      }
      r.readFloat();
      r.readFloat();
      if (r.readByte() === 2) {
        this.readBezierBlock(1);
      }
    }
  }

  private readTimeline2(frameCount: number): void {
    const r = this.r;
    const frameLast = frameCount - 1;
    let k = 0;
    while (k < 3) {
      r.readFloat();
      k++;
    }
    for (let f = 0; f < frameCount; f++) {
      if (f === frameLast) {
        break;
      }
      let m = 0;
      while (m < 3) {
        r.readFloat();
        m++;
      }
      if (r.readByte() === 2) {
        this.readBezierBlock(2);
      }
    }
  }

  /** 每段贝塞尔恒 4 个 float（cx1,cy1,cx2,cy2）。 */
  private readBezierBlock(count: number): void {
    const r = this.r;
    for (let i = 0; i < count; i++) {
      r.readFloat();
      r.readFloat();
      r.readFloat();
      r.readFloat();
    }
  }

  private readUnsignedBytes(count: number): void {
    const r = this.r;
    for (let i = 0; i < count; i++) {
      r.readUnsignedByte();
    }
  }
}

/** 名称健全性：长度 1..200，字符码 >=0x20 且不在 [0x7F..0x9F]。 */
function isValidPeekName(name: string): boolean {
  if (name.length < 1 || name.length > 200) {
    return false;
  }
  for (let i = 0; i < name.length; i++) {
    const c = name.charCodeAt(i);
    if (c < 0x20 || (c >= 0x7F && c <= 0x9F)) {
      return false;
    }
  }
  return true;
}

function isValidPeekNameList(names: Array<string>): boolean {
  for (const name of names) {
    if (!isValidPeekName(name)) {
      return false;
    }
  }
  return true;
}

/**
 * 二进制 .skel 预读取（内存版本）。
 * 门禁：EOF 精确匹配（动画是最后一段）/ 名称校验 / 头部 version 与检测版本一致；
 * 任一不满足或异常 → null。
 */
export function peekSkelBinary(bytes: Uint8Array, detectedVersion: string): SpinePeekResult | null {
  if (detectedVersion !== '4.0' && detectedVersion !== '4.1' && detectedVersion !== '4.2') {
    return null;
  }
  if (bytes.length < 16) {
    return null;
  }
  const reader = new SkelByteReader(bytes);
  const walker = new SkelPeekWalker(reader, detectedVersion);
  try {
    walker.walk();
  } catch (err) {
    console.error(`${TAG} walk failed at ${reader.offset}/${reader.length}: ${err}`);
    return null;
  }
  if (reader.offset !== bytes.length) {
    console.error(`${TAG} eof mismatch: ${reader.offset}/${reader.length}`);
    return null;
  }
  const headerVersion = walker.headerVersion;
  if (headerVersion !== '' && !headerVersion.startsWith(detectedVersion)) {
    console.error(`${TAG} version mismatch: '${headerVersion}' vs '${detectedVersion}'`);
    return null;
  }
  if (!isValidPeekNameList(walker.skins) || !isValidPeekNameList(walker.animations)) {
    console.error(`${TAG} name gate rejected`);
    return null;
  }
  const result = new SpinePeekResult();
  result.version = headerVersion;
  result.animations = walker.animations;
  result.skins = walker.skins;
  return result;
}

/** 二进制 .skel 预读取（文件版本，体积上限 64MB）。 */
export function peekSkelBinaryFile(skelPath: string, detectedVersion: string): SpinePeekResult | null {
  try {
    const stat = fileIo.statSync(skelPath);
    const size = stat.size;
    if (size <= 0 || size > MAX_SKEL_BYTES) {
      return null;
    }
    const file = fileIo.openSync(skelPath, fileIo.OpenMode.READ_ONLY);
    try {
      const buf = new ArrayBuffer(size);
      const readLen = fileIo.readSync(file.fd, buf);
      if (readLen <= 0) {
        return null;
      }
      const bytes = new Uint8Array(buf, 0, readLen);
      return peekSkelBinary(bytes, detectedVersion);
    } finally {
      fileIo.closeSync(file);
    }
  } catch (err) {
    console.error(`${TAG} read file failed: ${err}`);
    return null;
  }
}
