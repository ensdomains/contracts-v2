const ruleId = "natspec-triple-slash";

class NatspecTripleSlashChecker {
  ruleId = ruleId;
  meta = { fixable: true };

  constructor(reporter, config, inputSrc) {
    this.reporter = reporter;
    this.inputSrc = inputSrc;
    this._lines = null;
    this._reported = new Set();
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

  _findNatspecBlockComment(rangeStart) {
    this._initLines();
    const defLineIdx = this._getLineIndex(rangeStart);

    for (let i = defLineIdx - 1; i >= 0; i--) {
      const trimmed = this._lines[i].content.trimStart();

      if (trimmed === "") continue;
      if (/^\/\/\//.test(trimmed)) continue;

      if (/\*\/\s*$/.test(trimmed)) {
        for (let j = i; j >= 0; j--) {
          const jTrimmed = this._lines[j].content.trimStart();
          if (/^\/\*\*/.test(jTrimmed)) {
            return { startLineIdx: j, endLineIdx: i };
          }
          if (/^\/\*/.test(jTrimmed)) {
            return null;
          }
        }
        return null;
      }

      break;
    }

    return null;
  }

  _convertBlockToTripleSlash(startLineIdx, endLineIdx) {
    const lines = [];
    const indent = this._lines[startLineIdx].content.match(/^(\s*)/)[1];

    for (let i = startLineIdx; i <= endLineIdx; i++) {
      let text = this._lines[i].content.trimStart();

      if (i === endLineIdx) {
        text = text.replace(/\s*\*\/$/, "");
      }

      if (i === startLineIdx) {
        text = text.replace(/^\/\*\*\s?/, "");
      } else {
        text = text.replace(/^\*\s?/, "");
      }

      text = text.trimEnd();

      if ((i === startLineIdx || i === endLineIdx) && text === "") continue;

      if (text === "") {
        lines.push(`${indent}///`);
      } else {
        lines.push(`${indent}/// ${text}`);
      }
    }

    return lines.join("\n");
  }

  _checkNode(node) {
    if (!node || !node.range) return;
    this._initLines();

    const block = this._findNatspecBlockComment(node.range[0]);
    if (!block) return;

    const key = `${block.startLineIdx}:${block.endLineIdx}`;
    if (this._reported.has(key)) return;
    this._reported.add(key);

    const replacement = this._convertBlockToTripleSlash(
      block.startLineIdx,
      block.endLineIdx,
    );
    const startOffset = this._lines[block.startLineIdx].start;
    const endOffset = this._lines[block.endLineIdx].end - 1;

    this.reporter.error(
      node,
      this.ruleId,
      "NatSpec comments should use triple-slash (///) format instead of block (/** */) format",
      (fixer) => fixer.replaceTextRange([startOffset, endOffset], replacement),
    );
  }

  ContractDefinition(node) {
    this._checkNode(node);
  }
  FunctionDefinition(node) {
    this._checkNode(node);
  }
  EventDefinition(node) {
    this._checkNode(node);
  }
  CustomErrorDefinition(node) {
    this._checkNode(node);
  }
  StateVariableDeclaration(node) {
    this._checkNode(node);
  }
  ModifierDefinition(node) {
    this._checkNode(node);
  }
  StructDefinition(node) {
    this._checkNode(node);
  }
  EnumDefinition(node) {
    this._checkNode(node);
  }
}

module.exports = NatspecTripleSlashChecker;
