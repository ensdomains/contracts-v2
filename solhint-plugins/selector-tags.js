const { keccak256, toUtf8Bytes } = require("ethers");

const ruleId = "selector-tags";

const SELECTOR_TAG_RE =
  /@dev\s+(Error|Interface)\s+selector:\s*`(0x[0-9a-fA-F]+)`/;
const SELECTOR_CONTINUATION_RE =
  /(Error|Interface)\s+selector:\s*`(0x[0-9a-fA-F]+)`/;

class SelectorTagsChecker {
  ruleId = ruleId;
  meta = { fixable: true };

  constructor(reporter, config, inputSrc) {
    this.reporter = reporter;
    this.inputSrc = inputSrc;
    this.typeMap = new Map();
    this._lines = null;
  }

  _initLines() {
    if (this._lines) return;
    this._lines = [];
    const src = this.inputSrc;
    let start = 0;
    for (let i = 0; i <= src.length; i++) {
      if (i === src.length || src[i] === "\n") {
        this._lines.push({
          start,
          end: i,
          content: src.slice(start, i),
        });
        start = i + 1;
      }
    }
  }

  _getLineIndex(offset) {
    let lo = 0;
    let hi = this._lines.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (this._lines[mid].start <= offset) lo = mid;
      else hi = mid - 1;
    }
    return lo;
  }

  SourceUnit(node) {
    for (const child of node.children || []) {
      this._collectTypes(child);
    }
  }

  _collectTypes(node) {
    if (node.type === "ContractDefinition") {
      this.typeMap.set(node.name, { kind: node.kind });
      for (const sub of node.subNodes || []) {
        this._collectTypes(sub);
      }
    } else if (node.type === "EnumDefinition") {
      this.typeMap.set(node.name, { kind: "enum" });
    } else if (node.type === "StructDefinition") {
      this.typeMap.set(node.name, {
        kind: "struct",
        members: node.members,
      });
    }
  }

  _resolveType(typeName) {
    if (!typeName) return "";

    switch (typeName.type) {
      case "ElementaryTypeName":
        return typeName.name;

      case "UserDefinedTypeName": {
        const name = typeName.namePath;
        const info = this.typeMap.get(name);
        if (info) {
          if (info.kind === "enum") return "uint8";
          if (info.kind === "struct") {
            const memberTypes = info.members.map((m) =>
              this._resolveType(m.typeName),
            );
            return `(${memberTypes.join(",")})`;
          }
          return "address";
        }
        return "address";
      }

      case "ArrayTypeName": {
        const baseType = this._resolveType(typeName.baseTypeName);
        if (typeName.length != null) {
          const len =
            typeName.length.number ?? typeName.length.value ?? typeName.length;
          return `${baseType}[${len}]`;
        }
        return `${baseType}[]`;
      }

      default:
        return "unknown";
    }
  }

  _functionSignature(funcNode) {
    const paramTypes = (funcNode.parameters || []).map((p) =>
      this._resolveType(p.typeName),
    );
    return `${funcNode.name}(${paramTypes.join(",")})`;
  }

  _errorSignature(errorNode) {
    const paramTypes = (errorNode.parameters || []).map((p) =>
      this._resolveType(p.typeName),
    );
    return `${errorNode.name}(${paramTypes.join(",")})`;
  }

  _computeSelector(signature) {
    return keccak256(toUtf8Bytes(signature)).slice(0, 10);
  }

  _computeInterfaceId(functions) {
    let id = 0n;
    for (const func of functions) {
      const sig = this._functionSignature(func);
      const sel = BigInt(this._computeSelector(sig));
      id ^= sel;
    }
    return "0x" + id.toString(16).padStart(8, "0");
  }

  _findNatspecBlock(rangeStart) {
    this._initLines();
    const defLineIdx = this._getLineIndex(rangeStart);
    const block = [];

    for (let i = defLineIdx - 1; i >= 0; i--) {
      const line = this._lines[i];
      const trimmed = line.content.trimStart();
      if (/^\/\/\/(\s|$)/.test(trimmed)) {
        block.unshift({ ...line, lineIdx: i, trimmed });
      } else {
        break;
      }
    }

    return block;
  }

  _checkSelectorTag(node, kind, expectedSelector) {
    this._initLines();
    const block = this._findNatspecBlock(node.range[0]);

    let existingLine = null;
    let existingSelector = null;
    let isCanonicalFormat = false;

    for (const line of block) {
      const canonical = line.content.match(SELECTOR_TAG_RE);
      if (canonical && canonical[1] === kind) {
        existingLine = line;
        existingSelector = canonical[2];
        isCanonicalFormat = true;
        break;
      }
      const continuation = line.content.match(SELECTOR_CONTINUATION_RE);
      if (continuation && continuation[1] === kind) {
        existingLine = line;
        existingSelector = continuation[2];
        break;
      }
    }

    if (existingLine) {
      if (existingSelector === expectedSelector && isCanonicalFormat) return;

      if (isCanonicalFormat) {
        const message = `Incorrect ${kind.toLowerCase()} selector: expected \`${expectedSelector}\`, found \`${existingSelector}\``;
        this.reporter.error(node, this.ruleId, message, (fixer) => {
          const hexIdx = existingLine.content.indexOf(existingSelector);
          const hexStart = existingLine.start + hexIdx;
          const hexEnd = hexStart + existingSelector.length - 1;
          return fixer.replaceTextRange([hexStart, hexEnd], expectedSelector);
        });
      } else {
        const defLineIdx = this._getLineIndex(node.range[0]);
        const defLine = this._lines[defLineIdx];
        const indent = defLine.content.match(/^(\s*)/)[1];
        const canonical = `${indent}/// @dev ${kind} selector: \`${expectedSelector}\``;
        const message =
          existingSelector === expectedSelector
            ? `Non-canonical @dev ${kind.toLowerCase()} selector format`
            : `Incorrect ${kind.toLowerCase()} selector: expected \`${expectedSelector}\`, found \`${existingSelector}\``;
        this.reporter.error(node, this.ruleId, message, (fixer) =>
          fixer.replaceTextRange(
            [existingLine.start, existingLine.end - 1],
            canonical,
          ),
        );
      }
    } else {
      const message = `Missing @dev ${kind.toLowerCase()} selector tag (expected \`${expectedSelector}\`)`;

      const defLineIdx = this._getLineIndex(node.range[0]);
      const defLine = this._lines[defLineIdx];
      const indent = defLine.content.match(/^(\s*)/)[1];
      const newDevLine = `${indent}/// @dev ${kind} selector: \`${expectedSelector}\``;

      if (block.length > 0) {
        const nlPos = block[block.length - 1].end;
        if (nlPos < this.inputSrc.length) {
          this.reporter.error(node, this.ruleId, message, (fixer) =>
            fixer.replaceTextRange([nlPos, nlPos], `\n${newDevLine}\n`),
          );
        }
      } else {
        const prevNlPos = defLine.start - 1;
        if (prevNlPos >= 0) {
          this.reporter.error(node, this.ruleId, message, (fixer) =>
            fixer.replaceTextRange(
              [prevNlPos, prevNlPos],
              `\n${newDevLine}\n`,
            ),
          );
        } else {
          this.reporter.error(node, this.ruleId, message, (fixer) =>
            fixer.replaceTextRange(
              [0, 0],
              `${newDevLine}\n${this.inputSrc[0]}`,
            ),
          );
        }
      }
    }
  }

  ContractDefinition(node) {
    if (node.kind !== "interface") return;

    const functions = (node.subNodes || []).filter(
      (n) => n.type === "FunctionDefinition",
    );
    if (functions.length === 0) return;

    const expectedId = this._computeInterfaceId(functions);
    this._checkSelectorTag(node, "Interface", expectedId);
  }

  CustomErrorDefinition(node) {
    const sig = this._errorSignature(node);
    const expectedSelector = this._computeSelector(sig);
    this._checkSelectorTag(node, "Error", expectedSelector);
  }
}

module.exports = SelectorTagsChecker;
