const ruleId = "natspec";

const VALID_TAGS = new Set([
  "title",
  "author",
  "notice",
  "param",
  "return",
  "inheritdoc",
]);

const DEFAULT_TAG_CONFIG = {
  title: { enabled: false, skipInternal: false },
  author: { enabled: false, skipInternal: false },
  notice: { enabled: true, skipInternal: false },
  param: { enabled: true, skipInternal: false },
  return: { enabled: true, skipInternal: false },
};

const NATSPEC_TARGETS = {
  contract: ["title", "author", "notice"],
  library: ["title", "author", "notice"],
  interface: ["title", "author", "notice"],
  function: ["notice", "param", "return"],
  event: ["notice", "param"],
  variable: ["notice"],
};

class NatspecChecker {
  ruleId = ruleId;
  meta = { fixable: true };

  constructor(reporter, config, inputSrc, tokens) {
    this.reporter = reporter;
    this.inputSrc = inputSrc;
    this.tokens = tokens;
    this._lines = null;

    const userConfig = config?.getObject(ruleId) || {};
    this.tagConfig = {};
    for (const tag of Object.keys(DEFAULT_TAG_CONFIG)) {
      this.tagConfig[tag] = {
        ...DEFAULT_TAG_CONFIG[tag],
        ...(userConfig.tags?.[tag] || {}),
      };
    }
    this.continuationIndent = userConfig.continuationIndent || "padded";
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

  // Extract leading triple-slash NatSpec lines before a node
  _getNatspecLines(rangeStart) {
    this._initLines();
    const defLineIdx = this._getLineIndex(rangeStart);
    const block = [];

    for (let i = defLineIdx - 1; i >= 0; i--) {
      const line = this._lines[i];
      const trimmed = line.content.trimStart();
      if (/^\/\/\//.test(trimmed)) {
        block.unshift({ ...line, lineIdx: i, trimmed });
      } else {
        break;
      }
    }

    return block;
  }

  // Get leading NatSpec comment strings (for tag presence checks), using token stream
  _getLeadingNatSpecComments(startOffset) {
    const comments = [];

    for (let i = this.tokens.length - 1; i >= 0; i--) {
      const token = this.tokens[i];

      if (token.range[1] > startOffset) continue;

      const value = token.value?.trim();
      if (
        typeof value === "string" &&
        (value.startsWith("///") || value.startsWith("/**")) &&
        value.includes("@") &&
        this._hasAnyNatSpecTag(value)
      ) {
        comments.unshift(value);
      }

      if (!value || (!value.startsWith("///") && !value.startsWith("/**"))) {
        if (token.type !== "Punctuator") break;
      }
    }

    return comments;
  }

  _hasAnyNatSpecTag(commentValue) {
    for (const [, tag] of commentValue.matchAll(/@([a-zA-Z0-9_]+)/g)) {
      if (VALID_TAGS.has(tag)) return true;
    }
    return false;
  }

  _extractNatSpecTags(comments) {
    const tags = new Set();
    for (const comment of comments) {
      for (const [, tag] of comment.matchAll(/@([a-zA-Z0-9_]+)/g)) {
        tags.add(tag);
      }
    }
    return [...tags];
  }

  _extractTagNames(comments, tag) {
    const names = [];
    const regex = new RegExp(`@${tag}\\s+(\\w+)`, "g");
    for (const comment of comments) {
      let match = regex.exec(comment);
      while (match !== null) {
        names.push(match[1]);
        match = regex.exec(comment);
      }
    }
    return names;
  }

  _arraysEqual(a, b) {
    if (a.length !== b.length) return false;
    return a.every((v, i) => v === b[i]);
  }

  _checkContinuationIndent(node, natspecLines) {
    if (natspecLines.length === 0) return;

    let currentTagSpaces = null;

    for (const line of natspecLines) {
      const trimmed = line.trimmed; // already trimmed from left
      // Extract the part after `///`
      const afterSlashes = trimmed.slice(3); // everything after `///`

      const isTagLine = /^\s*@\w+/.test(afterSlashes);

      if (isTagLine) {
        // Count spaces between `///` and `@`
        const spaceMatch = afterSlashes.match(/^(\s*)/);
        currentTagSpaces = spaceMatch ? spaceMatch[1].length : 0;
      } else {
        // Continuation line
        if (currentTagSpaces === null) continue; // no preceding tag line yet

        const spaceMatch = afterSlashes.match(/^(\s*)/);
        const actualSpaces = spaceMatch ? spaceMatch[1].length : 0;
        const isEmptyLine = afterSlashes.trim() === "";

        if (isEmptyLine) continue; // blank /// lines are fine

        if (this.continuationIndent === "padded") {
          if (actualSpaces !== currentTagSpaces) {
            const expectedSpaces = currentTagSpaces;
            // Range of the existing spaces after `///`: they start right after `///`
            // within the line. line.start is the line's byte offset; trimmed drops
            // leading whitespace, so `///` sits at (line.start + leadingWhitespace).
            const leadingWs = line.content.length - trimmed.length;
            const slashesEnd = line.start + leadingWs + 3;
            const spacesEnd = slashesEnd + actualSpaces;
            const correctSpaces = " ".repeat(expectedSpaces);
            this.reporter.error(
              node,
              ruleId,
              `Continuation line indent mismatch: expected ${expectedSpaces} space(s) after ///, found ${actualSpaces}`,
              (fixer) =>
                fixer.replaceTextRange(
                  [slashesEnd, spacesEnd],
                  correctSpaces,
                ),
            );
          }
        } else if (this.continuationIndent === "none") {
          if (actualSpaces > 0) {
            const leadingWs = line.content.length - trimmed.length;
            const slashesEnd = line.start + leadingWs + 3;
            const spacesEnd = slashesEnd + actualSpaces;
            this.reporter.error(
              node,
              ruleId,
              `Continuation line must not have spaces after ///`,
              (fixer) => fixer.replaceTextRange([slashesEnd, spacesEnd], ""),
            );
          }
        }
      }
    }
  }

  _checkNode(node, type, tagsRequired, isInternalLike) {
    const name =
      node.name || (node.id && node.id.name) || "<anonymous>";
    const startOffset = node.range[0];
    const comments = this._getLeadingNatSpecComments(startOffset);
    const tags = this._extractNatSpecTags(comments);

    // If internal/private and no tags at all, skip entirely
    if (isInternalLike && tags.length === 0) return;

    // If @inheritdoc is present on a public/external node, skip tag checks
    if (!isInternalLike && tags.includes("inheritdoc")) {
      // Still check continuation indent
      const natspecLines = this._getNatspecLines(startOffset);
      this._checkContinuationIndent(node, natspecLines);
      return;
    }

    for (const tag of tagsRequired) {
      const rule = this.tagConfig[tag];
      if (!rule?.enabled) continue;

      // Skip this tag for internal/private if skipInternal is set
      if (isInternalLike && rule.skipInternal) continue;

      if (!tags.includes(tag)) {
        this.reporter.error(
          node,
          ruleId,
          `Missing @${tag} tag in ${type} '${name}'`,
        );
      }

      if (tag === "param") {
        const docParams = this._extractTagNames(comments, "param");
        const solidityParams = node.parameters || [];
        const namedParams = solidityParams
          .map((p) => p.name)
          .filter((n) => typeof n === "string" && n.length > 0);
        const allHaveNames = namedParams.length === solidityParams.length;

        if (allHaveNames) {
          if (
            namedParams.length !== docParams.length ||
            !this._arraysEqual(namedParams, docParams)
          ) {
            this.reporter.error(
              node,
              ruleId,
              `Mismatch in @param names for ${type} '${name}'. Expected: [${namedParams.join(", ")}], Found: [${docParams.join(", ")}]`,
            );
          }
        } else if (solidityParams.length !== docParams.length) {
          this.reporter.error(
            node,
            ruleId,
            `Mismatch in @param count for ${type} '${name}'. Expected: ${solidityParams.length}, Found: ${docParams.length}`,
          );
        }
      }

      if (tag === "return") {
        const docReturns = this._extractTagNames(comments, "return");
        const solidityReturns = node.returnParameters || [];
        const namedReturns = solidityReturns
          .map((p) => p.name)
          .filter((n) => typeof n === "string" && n.length > 0);
        const allHaveNames = namedReturns.length === solidityReturns.length;

        if (allHaveNames) {
          if (
            namedReturns.length !== docReturns.length ||
            !this._arraysEqual(namedReturns, docReturns)
          ) {
            this.reporter.error(
              node,
              ruleId,
              `Mismatch in @return names for ${type} '${name}'. Expected: [${namedReturns.join(", ")}], Found: [${docReturns.join(", ")}]`,
            );
          }
        } else if (solidityReturns.length !== docReturns.length) {
          this.reporter.error(
            node,
            ruleId,
            `Mismatch in @return count for ${type} '${name}'. Expected: ${solidityReturns.length}, Found: ${docReturns.length}`,
          );
        }
      }
    }

    // Check continuation indent for all nodes
    const natspecLines = this._getNatspecLines(startOffset);
    this._checkContinuationIndent(node, natspecLines);
  }

  ContractDefinition(node) {
    const tagsRequired = NATSPEC_TARGETS[node.kind] || NATSPEC_TARGETS.contract;
    this._checkNode(node, node.kind, tagsRequired, false);
  }

  FunctionDefinition(node) {
    const visibility = node.visibility || "default";
    const isInternalLike =
      visibility === "internal" || visibility === "private";

    const tags = [...NATSPEC_TARGETS.function];
    if (!node.parameters || node.parameters.length === 0) {
      const idx = tags.indexOf("param");
      if (idx !== -1) tags.splice(idx, 1);
    }
    if (!node.returnParameters || node.returnParameters.length === 0) {
      const idx = tags.indexOf("return");
      if (idx !== -1) tags.splice(idx, 1);
    }

    this._checkNode(node, "function", tags, isInternalLike);
  }

  EventDefinition(node) {
    const tags = [...NATSPEC_TARGETS.event];
    if (!node.parameters || node.parameters.length === 0) {
      const idx = tags.indexOf("param");
      if (idx !== -1) tags.splice(idx, 1);
    }
    this._checkNode(node, "event", tags, false);
  }

  StateVariableDeclaration(node) {
    // Only check public state variables
    const variables = node.variables || [];
    for (const variable of variables) {
      if (variable.visibility !== "public") continue;
      this._checkNode(node, "variable", NATSPEC_TARGETS.variable, false);
    }
  }
}

module.exports = NatspecChecker;
