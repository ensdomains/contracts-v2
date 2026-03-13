const ruleId = "natspec";

const DEFAULT_TAG_CONFIG = {
  title: { enabled: false },
  author: { enabled: false },
  notice: { enabled: true },
  dev: { enabled: false },
  param: { enabled: true },
  return: { enabled: true },
};

// Valid node contexts:
//   contract, library, interface,
//   function:external, function:public, function:internal, function:private, function:default,
//   event,
//   variable:public, variable:internal, variable:private,
//   error, struct, enum, custom-error
//
// Tag config supports `for` (inclusionary) or `skip` (exclusionary) arrays.
// Patterns: "function" matches all function visibilities, "function:internal" matches only internal.

const NATSPEC_TARGETS = {
  contract: ["title", "author", "notice", "dev"],
  library: ["title", "author", "notice", "dev"],
  interface: ["title", "author", "notice", "dev"],
  function: ["notice", "dev", "param", "return"],
  event: ["notice", "dev", "param"],
  variable: ["notice", "dev"],
};

class NatspecChecker {
  ruleId = ruleId;
  meta = { fixable: true };

  constructor(reporter, config, inputSrc) {
    this.reporter = reporter;
    this.inputSrc = inputSrc;
    this._lines = null;

    const userConfig =
      config?.getObject(`contracts-v2/${ruleId}`) ||
      config?.getObject(ruleId) ||
      {};
    this.tagConfig = {};
    for (const tag of Object.keys(DEFAULT_TAG_CONFIG)) {
      const defaults = DEFAULT_TAG_CONFIG[tag];
      const userTag = userConfig.tags?.[tag] || {};

      let includeList = userTag.include || null;
      let excludeList = userTag.exclude || null;

      // Backwards compat: skipInternal → exclude
      if (userTag.skipInternal === true && !includeList && !excludeList) {
        excludeList = ["function:internal", "function:private"];
      }

      this.tagConfig[tag] = {
        enabled: userTag.enabled ?? defaults.enabled,
        include: includeList,
        exclude: excludeList,
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

  // Get leading NatSpec comment strings (for tag presence checks)
  _getLeadingNatSpecComments(startOffset) {
    const natspecLines = this._getNatspecLines(startOffset);
    return natspecLines.map((line) => line.trimmed);
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

  _matchesContext(nodeContext, pattern) {
    if (pattern === nodeContext) return true;
    // "function" matches "function:external", "function:public", etc.
    if (!pattern.includes(":") && nodeContext.startsWith(pattern + ":")) return true;
    return false;
  }

  _shouldCheckTag(tag, nodeContext) {
    const rule = this.tagConfig[tag];
    if (!rule?.enabled) return false;

    if (rule.include) {
      return rule.include.some((p) => this._matchesContext(nodeContext, p));
    }
    if (rule.exclude) {
      return !rule.exclude.some((p) => this._matchesContext(nodeContext, p));
    }
    return true;
  }

  _checkSpacerLines(node, natspecLines, allowedGapOffsets) {
    if (natspecLines.length === 0) return;

    for (let i = 0; i < natspecLines.length; i++) {
      const line = natspecLines[i];
      const afterSlashes = line.trimmed.slice(3);
      const isEmpty = afterSlashes.trim() === "";

      if (!isEmpty) continue;
      if (allowedGapOffsets && allowedGapOffsets.has(line.start)) continue;

      // Check if the next non-empty natspec line starts with a @tag
      for (let j = i + 1; j < natspecLines.length; j++) {
        const nextAfter = natspecLines[j].trimmed.slice(3);
        if (nextAfter.trim() === "") continue;
        if (/^\s*@\w+/.test(nextAfter)) {
          this.reporter.error(
            node,
            ruleId,
            `Unnecessary spacer line before @tag`,
            (fixer) => fixer.replaceTextRange([line.start, line.end], ""),
          );
        }
        break;
      }
    }
  }

  _checkContinuationIndent(node, natspecLines) {
    const allowedGapOffsets = new Set();
    if (natspecLines.length === 0) return allowedGapOffsets;
    if (this.continuationIndent === "none") {
      this._checkContinuationIndentNone(node, natspecLines);
      return allowedGapOffsets;
    }

    // Group all lines by their preceding tag.
    const tagGroups = [];
    let currentGroup = null;

    for (const line of natspecLines) {
      const trimmed = line.trimmed;
      const afterSlashes = trimmed.slice(3);
      const isTagLine = /^\s*@\w+/.test(afterSlashes);
      const isEmpty = afterSlashes.trim() === "";

      if (isTagLine) {
        const tagMatch = afterSlashes.match(/^(\s*@\w+)\s?/);
        const expectedSpaces = tagMatch ? tagMatch[0].length : 0;
        currentGroup = { expectedSpaces, continuations: [] };
        tagGroups.push(currentGroup);
      } else if (currentGroup) {
        const spaceMatch = afterSlashes.match(/^(\s*)/);
        const actualSpaces = spaceMatch ? spaceMatch[1].length : 0;
        currentGroup.continuations.push({
          line,
          trimmed,
          afterSlashes,
          isEmpty,
          actualSpaces,
        });
      }
    }

    for (let gi = 0; gi < tagGroups.length; gi++) {
      const group = tagGroups[gi];
      if (group.continuations.length === 0) continue;

      const totalLines = 1 + group.continuations.length;
      const hasNonTrailingGap = group.continuations.some(
        (l, i) => l.isEmpty && i < group.continuations.length - 1,
      );

      if (totalLines > 4 || hasNonTrailingGap) {
        const hasNextTag = gi < tagGroups.length - 1;
        this._checkLongBlockIndent(node, group, hasNextTag, allowedGapOffsets);
      } else {
        this._checkShortBlockIndent(node, group);
      }
    }

    return allowedGapOffsets;
  }

  _checkLongBlockIndent(node, group, hasNextTag, allowedGapOffsets) {
    const padding = group.expectedSpaces - 1;

    if (padding > 0) {
      for (const entry of group.continuations) {
        if (entry.isEmpty) continue;
        if (entry.actualSpaces < group.expectedSpaces) continue;

        const correctedSpaces = entry.actualSpaces - padding;
        const leadingWs = entry.line.content.length - entry.trimmed.length;
        const slashesEnd = entry.line.start + leadingWs + 3;
        const correctSpaces = " ".repeat(correctedSpaces);

        this.reporter.error(
          node,
          ruleId,
          `Long natspec block should not use tag-level padding`,
          (fixer) =>
            fixer.replaceTextRange(
              [slashesEnd, slashesEnd + entry.actualSpaces - 1],
              correctSpaces,
            ),
        );
      }
    }

    // Enforce trailing empty /// line at the end of long blocks
    const last = group.continuations[group.continuations.length - 1];
    if (last.isEmpty) {
      if (hasNextTag) allowedGapOffsets.add(last.line.start);
    } else {
      const indent = last.line.content.slice(
        0,
        last.line.content.length - last.trimmed.length,
      );
      this.reporter.error(
        node,
        ruleId,
        `Long natspec block missing trailing empty line`,
        (fixer) =>
          fixer.replaceTextRange(
            [last.line.end, last.line.end],
            `\n${indent}///\n`,
          ),
      );
    }
  }

  _checkShortBlockIndent(node, group) {
    // Split into segments on empty lines
    const segments = [];
    let currentSegment = { expectedSpaces: group.expectedSpaces, lines: [] };
    segments.push(currentSegment);

    for (const entry of group.continuations) {
      if (entry.isEmpty) {
        currentSegment = {
          expectedSpaces: group.expectedSpaces,
          lines: [],
        };
        segments.push(currentSegment);
        continue;
      }
      currentSegment.lines.push(entry);
    }

    // For each segment, find the minimum indent among its continuation lines.
    // If the minimum is less than expected, shift ALL lines in that segment
    // by the deficit, preserving their relative indentation.
    for (const seg of segments) {
      if (seg.lines.length === 0) continue;

      const minIndent = Math.min(...seg.lines.map((l) => l.actualSpaces));
      if (minIndent >= seg.expectedSpaces) continue;

      const delta = seg.expectedSpaces - minIndent;

      for (const entry of seg.lines) {
        const correctedSpaces = entry.actualSpaces + delta;
        const leadingWs = entry.line.content.length - entry.trimmed.length;
        const slashesEnd = entry.line.start + leadingWs + 3;
        const correctSpaces = " ".repeat(correctedSpaces);
        if (entry.actualSpaces > 0) {
          this.reporter.error(
            node,
            ruleId,
            `Continuation line under-indented: expected at least ${seg.expectedSpaces} space(s) after ///, found ${minIndent}`,
            (fixer) =>
              fixer.replaceTextRange(
                [slashesEnd, slashesEnd + entry.actualSpaces - 1],
                correctSpaces,
              ),
          );
        } else {
          const charAtPos = this.inputSrc[slashesEnd] || "";
          this.reporter.error(
            node,
            ruleId,
            `Continuation line under-indented: expected at least ${seg.expectedSpaces} space(s) after ///, found ${minIndent}`,
            (fixer) =>
              fixer.replaceTextRange(
                [slashesEnd, slashesEnd],
                correctSpaces + charAtPos,
              ),
          );
        }
      }
    }
  }

  _checkContinuationIndentNone(node, natspecLines) {
    for (const line of natspecLines) {
      const trimmed = line.trimmed;
      const afterSlashes = trimmed.slice(3);
      if (/^\s*@\w+/.test(afterSlashes)) continue;
      if (afterSlashes.trim() === "") continue;

      const spaceMatch = afterSlashes.match(/^(\s*)/);
      const actualSpaces = spaceMatch ? spaceMatch[1].length : 0;
      if (actualSpaces > 0) {
        const leadingWs = line.content.length - trimmed.length;
        const slashesEnd = line.start + leadingWs + 3;
        this.reporter.error(
          node,
          ruleId,
          `Continuation line must not have spaces after ///`,
          (fixer) =>
            fixer.replaceTextRange(
              [slashesEnd, slashesEnd + actualSpaces - 1],
              "",
            ),
        );
      }
    }
  }

  _checkNode(node, type, tagsRequired, nodeContext) {
    const name = node.name || (node.id && node.id.name) || "<anonymous>";
    const startOffset = node.range[0];
    const comments = this._getLeadingNatSpecComments(startOffset);
    const tags = this._extractNatSpecTags(comments);

    // Determine which tags are required for this context
    const applicableTags = tagsRequired.filter((t) =>
      this._shouldCheckTag(t, nodeContext),
    );

    // If no tags required and no natspec present, skip entirely
    if (applicableTags.length === 0 && tags.length === 0) return;

    // If @inheritdoc is present, skip tag checks but still check formatting
    if (tags.includes("inheritdoc")) {
      const natspecLines = this._getNatspecLines(startOffset);
      const allowedGaps = this._checkContinuationIndent(node, natspecLines);
      this._checkSpacerLines(node, natspecLines, allowedGaps);
      return;
    }

    for (const tag of applicableTags) {
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

    // Check formatting for all nodes
    const natspecLines = this._getNatspecLines(startOffset);
    const allowedGaps = this._checkContinuationIndent(node, natspecLines);
    this._checkSpacerLines(node, natspecLines, allowedGaps);
  }

  ContractDefinition(node) {
    const kind = node.kind || "contract";
    const tagsRequired = NATSPEC_TARGETS[kind] || NATSPEC_TARGETS.contract;
    this._checkNode(node, kind, tagsRequired, kind);
  }

  FunctionDefinition(node) {
    const visibility = node.visibility || "default";
    const nodeContext = `function:${visibility}`;

    const tags = [...NATSPEC_TARGETS.function];
    if (!node.parameters || node.parameters.length === 0) {
      const idx = tags.indexOf("param");
      if (idx !== -1) tags.splice(idx, 1);
    }
    if (!node.returnParameters || node.returnParameters.length === 0) {
      const idx = tags.indexOf("return");
      if (idx !== -1) tags.splice(idx, 1);
    }

    this._checkNode(node, "function", tags, nodeContext);
  }

  EventDefinition(node) {
    const tags = [...NATSPEC_TARGETS.event];
    if (!node.parameters || node.parameters.length === 0) {
      const idx = tags.indexOf("param");
      if (idx !== -1) tags.splice(idx, 1);
    }
    this._checkNode(node, "event", tags, "event");
  }

  StateVariableDeclaration(node) {
    const variables = node.variables || [];
    for (const variable of variables) {
      const visibility = variable.visibility || "internal";
      this._checkNode(
        node,
        "variable",
        NATSPEC_TARGETS.variable,
        `variable:${visibility}`,
      );
    }
  }
}

module.exports = NatspecChecker;
