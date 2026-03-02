const ruleId = "category-headers";

const ALWAYS_VALID = new Set([
  "Storage",
  "Events",
  "Errors",
  "Initialization",
  "Types",
  "Modifiers",
]);

const CONSTANTS_NAMES = new Set([
  "Constants & Immutables",
  "Constants",
  "Immutables",
]);

const FUNCTION_SECTION_NAMES = new Set([
  "Functions",
  "Implementation",
  "Internal Functions",
  "Private Functions",
]);

const DEFAULT_INIT_FUNCTIONS = new Set([
  "constructor",
  "supportsInterface",
  "supportsFeature",
  "initialize",
]);

const CATEGORY_ORDER = [
  "Types",
  "Constants & Immutables",
  "Constants",
  "Immutables",
  "Storage",
  "Events",
  "Errors",
  "Modifiers",
  "Initialization",
  "Functions",
  "Implementation",
  "Internal Functions",
  "Private Functions",
];

const DIVIDER_RE = /^\s*\/{72}\s*$/;
const COMMENT_RE = /^\s*\/\/\s+(.+?)\s*$/;

class CategoryHeadersChecker {
  ruleId = ruleId;
  meta = { fixable: true };

  constructor(reporter, config, inputSrc) {
    this.reporter = reporter;
    this.inputSrc = inputSrc;
    this._lines = null;
    this._categoryBlocks = [];
    this._contractRanges = [];
    this._skippedContracts = new Set();
    this._pendingMoves = new Map();

    const userConfig =
      config?.getObject(`contracts-v2/${ruleId}`) ||
      config?.getObject(ruleId) ||
      {};
    this.minCategories = userConfig.minCategories ?? 2;

    const userInitFns = userConfig.initializationFunctions;
    if (Array.isArray(userInitFns) && userInitFns.length > 0) {
      this.initializationFunctions = new Set(userInitFns);
    } else {
      this.initializationFunctions = DEFAULT_INIT_FUNCTIONS;
    }
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

  _scanCategoryHeaders() {
    this._categoryBlocks = [];
    const lines = this._lines;
    for (let i = 0; i < lines.length - 2; i++) {
      if (!DIVIDER_RE.test(lines[i].content)) continue;
      const nameMatch = COMMENT_RE.exec(lines[i + 1].content);
      if (!nameMatch) continue;
      if (!DIVIDER_RE.test(lines[i + 2].content)) continue;

      const indent = lines[i].content.match(/^(\s*)/)[1];
      const nameLineStart = lines[i + 1].start;
      const nameLineEnd = lines[i + 1].end;

      this._categoryBlocks.push({
        name: nameMatch[1],
        lineIdx: i + 1,
        indent,
        startOffset: lines[i].start,
        endOffset: lines[i + 2].end,
        nameLineStart,
        nameLineEnd,
        // blockWithNewline includes the trailing \n so deleting a whole block is clean
        blockWithNewlineEnd: lines[i + 2].end + 1,
      });
    }
  }

  _blocksInRange(start, end) {
    return this._categoryBlocks.filter(
      (b) => b.startOffset >= start && b.endOffset <= end,
    );
  }

  _nearestCategoryBefore(offset, contractStart, contractEnd) {
    const blocks = this._blocksInRange(contractStart, contractEnd);
    let nearest = null;
    for (const b of blocks) {
      if (b.startOffset < offset) {
        nearest = b;
      }
    }
    return nearest;
  }

  _isInitFunction(name) {
    if (this.initializationFunctions.has(name)) return true;
    if (name.startsWith("_init") || name.startsWith("__init")) return true;
    return false;
  }

  _findNatspecBlock(rangeStart) {
    const defLineIdx = this._getLineIndex(rangeStart);
    const block = [];
    for (let i = defLineIdx - 1; i >= 0; i--) {
      const line = this._lines[i];
      if (/^\s*\/\/\/(\s|$)/.test(line.content)) {
        block.unshift(line);
      } else {
        break;
      }
    }
    return block;
  }

  _buildHeaderBlock(indent, name) {
    const divider = indent + "/".repeat(72);
    return `${divider}\n${indent}// ${name}\n${divider}\n`;
  }

  _findInsertionPoint(targetCategory, contractStart, contractEnd) {
    const blocks = this._blocksInRange(contractStart, contractEnd);
    const targetBlock = blocks.find((b) => b.name === targetCategory);

    // Determine the indentation from existing headers or fall back to 4 spaces
    const indent = blocks.length > 0 ? blocks[0].indent : "    ";

    if (targetBlock) {
      // Target header exists — insert at end of its section
      const targetIdx = blocks.indexOf(targetBlock);
      if (targetIdx < blocks.length - 1) {
        // Insert before the next header block
        return { offset: blocks[targetIdx + 1].startOffset, headerNeeded: false, indent };
      } else {
        // Last header section — insert before the contract's closing brace
        const closingLineIdx = this._getLineIndex(contractEnd);
        return { offset: this._lines[closingLineIdx].start, headerNeeded: false, indent };
      }
    }

    // Target header doesn't exist — find where to create it based on CATEGORY_ORDER
    const targetOrderIdx = CATEGORY_ORDER.indexOf(targetCategory);
    let insertBeforeBlock = null;
    for (const block of blocks) {
      const blockOrderIdx = CATEGORY_ORDER.indexOf(block.name);
      if (blockOrderIdx > targetOrderIdx) {
        insertBeforeBlock = block;
        break;
      }
    }

    if (insertBeforeBlock) {
      return { offset: insertBeforeBlock.startOffset, headerNeeded: true, indent };
    }

    // No existing header comes after — insert before the contract's closing brace
    const closingLineIdx = this._getLineIndex(contractEnd);
    return { offset: this._lines[closingLineIdx].start, headerNeeded: true, indent };
  }

  _findEnclosingContract(offset) {
    for (const cr of this._contractRanges) {
      if (offset >= cr.start && offset <= cr.end) {
        return cr;
      }
    }
    return null;
  }

  _countDeclarationCategories(node) {
    const categories = new Set();
    const subNodes = node.subNodes || [];
    for (const child of subNodes) {
      switch (child.type) {
        case "StateVariableDeclaration": {
          const v = child.variables?.[0];
          if (v?.isDeclaredConst || v?.isImmutable) {
            categories.add("Constants");
          } else {
            categories.add("Storage");
          }
          break;
        }
        case "EventDefinition":
          categories.add("Events");
          break;
        case "CustomErrorDefinition":
          categories.add("Errors");
          break;
        case "StructDefinition":
        case "EnumDefinition":
          categories.add("Types");
          break;
        case "ModifierDefinition":
          categories.add("Modifiers");
          break;
        case "FunctionDefinition": {
          if (child.isFallback || child.isReceiveEther) {
            categories.add("Functions");
          } else {
            const fnName = child.isConstructor ? "constructor" : child.name;
            if (this._isInitFunction(fnName)) {
              categories.add("Initialization");
            } else {
              categories.add("Functions");
            }
          }
          break;
        }
      }
    }
    return categories.size;
  }

  _expectedCategory(node, fnName) {
    if (this._isInitFunction(fnName)) {
      return "Initialization";
    }

    if (node.isFallback || node.isReceiveEther) {
      return "Implementation";
    }

    const visibility = node.visibility || "default";

    if (
      visibility === "public" ||
      visibility === "external" ||
      visibility === "default"
    ) {
      return "Implementation";
    }
    if (visibility === "internal") {
      return "Internal Functions";
    }
    if (visibility === "private") {
      return "Private Functions";
    }

    return null;
  }

  // Build the replacement text for the "// Name" portion of a header line
  _makeNameLine(indent, newName) {
    return `${indent}// ${newName}`;
  }

  // Report a conflict where firstBlock should be renamed and secondBlock deleted.
  // Each block gets its own reporter.error call with its own fixer.
  _reportMergeConflict(node, firstBlock, secondBlock, combinedName, message) {
    // Fix for firstBlock: rename its label line to combinedName
    // Range end is inclusive in solhint's applyFixes
    this.reporter.error(node, ruleId, message, (fixer) =>
      fixer.replaceTextRange(
        [firstBlock.nameLineStart, firstBlock.nameLineEnd - 1],
        this._makeNameLine(firstBlock.indent, combinedName),
      ),
    );

    // Fix for secondBlock: delete the entire block (including trailing newline)
    // Range end is inclusive in solhint's applyFixes
    const deleteEnd = Math.min(
      secondBlock.blockWithNewlineEnd,
      this.inputSrc.length,
    ) - 1;
    this.reporter.error(node, ruleId, message, (fixer) =>
      fixer.replaceTextRange([secondBlock.startOffset, deleteEnd], ""),
    );
  }

  SourceUnit(node) {
    this._initLines();
    this._scanCategoryHeaders();
    this._contractRanges = [];

    const collect = (nodes) => {
      if (!nodes) return;
      for (const child of nodes) {
        if (child && child.type === "ContractDefinition" && child.range) {
          this._contractRanges.push({
            start: child.range[0],
            end: child.range[1],
            contractKind: child.kind,
          });
        }
      }
    };
    collect(node.children);
  }

  ContractDefinition(node) {
    if (!node.range) return;
    const [contractStart, contractEnd] = node.range;
    const blocks = this._blocksInRange(contractStart, contractEnd);

    // Skip validation for contracts with fewer declaration categories than the threshold
    if (this._countDeclarationCategories(node) < this.minCategories) {
      this._skippedContracts.add(`${contractStart}:${contractEnd}`);
      return;
    }

    // Validate each block's name (no fix for unknown names)
    for (const block of blocks) {
      const { name } = block;
      if (
        !ALWAYS_VALID.has(name) &&
        !CONSTANTS_NAMES.has(name) &&
        !FUNCTION_SECTION_NAMES.has(name)
      ) {
        this.reporter.error(node, ruleId, `Unknown category name '${name}'`);
      }
    }

    // Constants conflict checks
    const hasConstantsAndImmutables = blocks.some(
      (b) => b.name === "Constants & Immutables",
    );
    const constantsBlock = blocks.find((b) => b.name === "Constants");
    const immutablesBlock = blocks.find((b) => b.name === "Immutables");

    if (constantsBlock && immutablesBlock) {
      // Both separate — rename first to combined, delete second
      const [first, second] =
        constantsBlock.startOffset < immutablesBlock.startOffset
          ? [constantsBlock, immutablesBlock]
          : [immutablesBlock, constantsBlock];
      this._reportMergeConflict(
        node,
        first,
        second,
        "Constants & Immutables",
        `Use 'Constants & Immutables' instead of separate 'Constants' and 'Immutables' headers`,
      );
    } else if (hasConstantsAndImmutables && (constantsBlock || immutablesBlock)) {
      // Combined already exists — delete the stray individual block
      const stray = constantsBlock || immutablesBlock;
      const deleteEnd = Math.min(
        stray.blockWithNewlineEnd,
        this.inputSrc.length,
      ) - 1;
      this.reporter.error(
        node,
        ruleId,
        `Use 'Constants & Immutables' instead of separate 'Constants' and 'Immutables' headers`,
        (fixer) =>
          fixer.replaceTextRange([stray.startOffset, deleteEnd], ""),
      );
    }

    // Library: 'Internal Functions' alongside 'Implementation' — rename to 'Implementation'
    if (node.kind === "library") {
      const hasImplementation = blocks.some((b) => b.name === "Implementation");
      const internalFnsBlock = blocks.find((b) => b.name === "Internal Functions");
      if (hasImplementation && internalFnsBlock) {
        this.reporter.error(
          node,
          ruleId,
          `Use 'Implementation' for library functions (not 'Internal Functions')`,
          (fixer) =>
            fixer.replaceTextRange(
              [internalFnsBlock.nameLineStart, internalFnsBlock.nameLineEnd - 1],
              this._makeNameLine(internalFnsBlock.indent, "Implementation"),
            ),
        );
      }
    }

  }

  FunctionDefinition(node) {
    if (!node.range) return;

    const fnName = node.isConstructor
      ? "constructor"
      : node.isFallback
        ? "fallback"
        : node.isReceiveEther
          ? "receive"
          : node.name;
    const expectedCategory = this._expectedCategory(node, fnName);
    if (!expectedCategory) return;

    const contractInfo = this._findEnclosingContract(node.range[0]);
    if (!contractInfo) return;

    const { start: contractStart, end: contractEnd, contractKind } = contractInfo;

    // Skip function placement checks for contracts below the category threshold
    if (this._skippedContracts.has(`${contractStart}:${contractEnd}`)) return;

    const nearestBlock = this._nearestCategoryBefore(
      node.range[0],
      contractStart,
      contractEnd,
    );

    const actualCategory = nearestBlock ? nearestBlock.name : null;

    let resolvedExpected = expectedCategory;
    if (contractKind === "interface") {
      resolvedExpected = "Functions";
    } else if (contractKind === "library" && resolvedExpected === "Internal Functions") {
      resolvedExpected = "Implementation";
    }

    if (actualCategory !== resolvedExpected) {
      const messageCategory = resolvedExpected;

      const message = `Function '${fnName}' should be under the '${messageCategory}' category`;
      const contractKey = `${contractStart}:${contractEnd}`;

      // Determine extraction range (function + NatSpec)
      const natspecBlock = this._findNatspecBlock(node.range[0]);
      const defLineIdx = this._getLineIndex(node.range[0]);
      const endLineIdx = this._getLineIndex(node.range[1]);

      let extractStartLineIdx = natspecBlock.length > 0
        ? this._getLineIndex(natspecBlock[0].start)
        : defLineIdx;

      let extractEndLineIdx = endLineIdx;

      // Consume an adjacent blank line to avoid leaving double blanks after deletion.
      // Prefer consuming a trailing blank line, but not if it precedes a category header.
      const trailingBlankIdx = extractEndLineIdx + 1;
      const hasTrailingBlank = trailingBlankIdx < this._lines.length &&
        this._lines[trailingBlankIdx].content.trim() === "";
      const trailingBlankBeforeHeader = hasTrailingBlank &&
        trailingBlankIdx + 1 < this._lines.length &&
        DIVIDER_RE.test(this._lines[trailingBlankIdx + 1].content);

      if (hasTrailingBlank && !trailingBlankBeforeHeader) {
        extractEndLineIdx++;
      } else if (extractStartLineIdx > 0 &&
        this._lines[extractStartLineIdx - 1].content.trim() === "") {
        // Don't consume the blank line if it follows a category header divider
        const precedingBlankIdx = extractStartLineIdx - 1;
        const afterHeader = precedingBlankIdx > 0 &&
          DIVIDER_RE.test(this._lines[precedingBlankIdx - 1].content);
        if (!afterHeader) {
          extractStartLineIdx--;
        }
      }

      const extractStart = this._lines[extractStartLineIdx].start;
      const extractEnd = this._lines[extractEndLineIdx].end + 1;

      let functionText = this.inputSrc.slice(extractStart, extractEnd);
      functionText = functionText.replace(/^\n+/, "").replace(/\n+$/, "\n");

      // Collect this move for batched processing in ContractDefinition:exit
      if (!this._pendingMoves.has(contractKey)) {
        this._pendingMoves.set(contractKey, []);
      }
      this._pendingMoves.get(contractKey).push({
        node,
        message,
        messageCategory,
        extractStart,
        extractEnd,
        functionText,
        contractStart,
        contractEnd,
      });
    }
  }

  "ContractDefinition:exit"(node) {
    if (!node.range) return;
    const [contractStart, contractEnd] = node.range;
    const contractKey = `${contractStart}:${contractEnd}`;

    const moves = this._pendingMoves.get(contractKey);
    if (!moves || moves.length === 0) return;
    this._pendingMoves.delete(contractKey);

    // Group moves by their target insertion offset
    const insertionGroups = new Map(); // offset -> { headerNeeded, indent, entries: MoveEntry[] }
    for (const move of moves) {
      const { offset, headerNeeded, indent } =
        this._findInsertionPoint(move.messageCategory, move.contractStart, move.contractEnd);

      if (!insertionGroups.has(offset)) {
        insertionGroups.set(offset, []);
      }
      insertionGroups.get(offset).push({ ...move, headerNeeded, indent });
    }

    // Build all fix descriptors
    const fixes = [];

    // Collect extractStart offsets of entries that are already at their insertion point.
    // These don't need to be deleted and reinserted — they just need a header.
    const inPlaceExtractStarts = new Set();

    // Insert fixes — one per unique insertion offset
    for (const [insertOffset, entries] of insertionGroups) {
      // Sort entries within this group by CATEGORY_ORDER, then by original source position
      entries.sort((a, b) => {
        const catA = CATEGORY_ORDER.indexOf(a.messageCategory);
        const catB = CATEGORY_ORDER.indexOf(b.messageCategory);
        if (catA !== catB) return catA - catB;
        return a.extractStart - b.extractStart;
      });

      // Identify entries that are already at the insertion point.
      // An entry is "in place" if its extract range contains the insert offset,
      // meaning it would overlap with the insert fix.
      for (const entry of entries) {
        if (insertOffset >= entry.extractStart && insertOffset < entry.extractEnd) {
          inPlaceExtractStarts.add(entry.extractStart);
        }
      }

      // Filter to only entries that actually need to be moved (not in-place)
      const movedEntries = entries.filter((e) => !inPlaceExtractStarts.has(e.extractStart));

      // Subgroup by messageCategory to determine where headers are needed
      const subgroups = [];
      let currentSubgroup = null;
      for (const entry of movedEntries) {
        if (!currentSubgroup || currentSubgroup.category !== entry.messageCategory) {
          currentSubgroup = { category: entry.messageCategory, entries: [entry] };
          subgroups.push(currentSubgroup);
        } else {
          currentSubgroup.entries.push(entry);
        }
      }

      // Determine if any subgroup needs a header
      const anyHeaderNeeded = entries.some((e) => e.headerNeeded);

      const insertLineIdx = this._getLineIndex(insertOffset);
      let hasBlankLineBeforeInsert = insertLineIdx > 0 &&
        this._lines[insertLineIdx - 1].content.trim() === "";

      // Also check if deletions will leave a residual blank line before the insert point.
      // Find the earliest extractStart among all entries targeting this offset.
      // If a blank line precedes that, it will remain after deletions.
      if (!hasBlankLineBeforeInsert && movedEntries.length > 0) {
        const earliestExtractStart = Math.min(...movedEntries.map((e) => e.extractStart));
        const earliestLineIdx = this._getLineIndex(earliestExtractStart);
        if (earliestLineIdx > 0 &&
          this._lines[earliestLineIdx - 1].content.trim() === "") {
          hasBlankLineBeforeInsert = true;
        }
      }

      let insertText = "";

      // If a header is needed and we only have in-place entries (no moved entries),
      // just insert the header
      if (anyHeaderNeeded && subgroups.length === 0) {
        const indent = entries[0].indent;
        if (!hasBlankLineBeforeInsert) {
          insertText += "\n";
        }
        insertText += this._buildHeaderBlock(indent, entries[0].messageCategory) + "\n";
      }

      for (let gi = 0; gi < subgroups.length; gi++) {
        const subgroup = subgroups[gi];
        const needsHeader = subgroup.entries[0].headerNeeded;
        const indent = subgroup.entries[0].indent;

        if (needsHeader) {
          if (gi === 0 && !hasBlankLineBeforeInsert) {
            insertText += "\n";
          } else if (gi > 0) {
            insertText += "\n";
          }
          insertText += this._buildHeaderBlock(indent, subgroup.category) + "\n";
        } else {
          if (gi === 0 && !hasBlankLineBeforeInsert) {
            insertText += "\n";
          }
        }

        for (let fi = 0; fi < subgroup.entries.length; fi++) {
          if (fi > 0 || (!needsHeader && gi > 0)) {
            insertText += "\n";
          }
          insertText += subgroup.entries[fi].functionText;
        }
      }

      if (insertText === "") continue;

      // Preserve the character at insertOffset
      const preservedChar = this.inputSrc[insertOffset] || "";
      const insertReplacement = insertText + preservedChar;

      fixes.push({
        range: [insertOffset, insertOffset],
        text: insertReplacement,
        node: entries[0].node,
        message: entries[0].message,
      });
    }

    // Delete fixes — only for functions that actually need to move
    for (const move of moves) {
      if (inPlaceExtractStarts.has(move.extractStart)) continue;
      fixes.push({
        range: [move.extractStart, move.extractEnd - 1],
        text: "",
        node: move.node,
        message: move.message,
      });
    }

    // Sort all fixes by range[0] ascending
    fixes.sort((a, b) => a.range[0] - b.range[0]);

    // Check for overlaps
    let hasOverlap = false;
    for (let i = 1; i < fixes.length; i++) {
      if (fixes[i].range[0] < fixes[i - 1].range[1]) {
        hasOverlap = true;
        break;
      }
    }

    if (hasOverlap) {
      // Fall back to error-only reporting (no fixers)
      for (const move of moves) {
        this.reporter.error(move.node, ruleId, move.message);
      }
      return;
    }

    // Emit all fixes
    for (const fix of fixes) {
      const fixRange = fix.range;
      const fixText = fix.text;
      this.reporter.error(fix.node, ruleId, fix.message, (fixer) =>
        fixer.replaceTextRange(fixRange, fixText),
      );
    }
  }
}

module.exports = CategoryHeadersChecker;
