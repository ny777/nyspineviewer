/**
 * 模型库条目数据类（对齐 Android 版 SpineModelItem.kt，分组字段按本期范围裁剪）。
 */
export class SpineModelItem {
  id: string;
  name: string;
  /** 模型目录沙箱绝对路径。 */
  folderPath: string;
  /** 骨架文件名（相对 folderPath）。 */
  skelFile: string;
  /** 图集文件名（相对 folderPath），可能为空串。 */
  atlasFile: string;
  animations: Array<string>;
  skins: Array<string>;
  /** 短版本串，如 "4.1" / "unknown"。 */
  version: string;
  /** "SKEL" | "JSON"。 */
  format: string;
  createdAt: number;

  constructor(id: string, name: string, folderPath: string, skelFile: string,
    atlasFile: string, animations: Array<string>, skins: Array<string>,
    version: string, format: string, createdAt: number) {
    this.id = id;
    this.name = name;
    this.folderPath = folderPath;
    this.skelFile = skelFile;
    this.atlasFile = atlasFile;
    this.animations = animations;
    this.skins = skins;
    this.version = version;
    this.format = format;
    this.createdAt = createdAt;
  }

  /** 当前集成的 runtime 是否可直接播放（本期仅 4.1）。 */
  isSupported(): boolean {
    return this.version === '4.1';
  }

  /** 骨架文件沙箱绝对路径。 */
  skelPath(): string {
    return `${this.folderPath}/${this.skelFile}`;
  }

  /** 图集文件沙箱绝对路径（无图集返回空串）。 */
  atlasPath(): string {
    if (this.atlasFile.length === 0) {
      return '';
    }
    return `${this.folderPath}/${this.atlasFile}`;
  }
}
