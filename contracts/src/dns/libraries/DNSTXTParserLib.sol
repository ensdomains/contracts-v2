// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {BytesUtils} from "@ens/contracts/utils/BytesUtils.sol";

/// @dev Library for parsing ENS records from DNS TXT data.
///
/// The record data consists of a series of key=value pairs, separated by spaces.
///
/// Keys may have an optional argument in square brackets.
/// Keys may contain additional square brackets but they must be balanced.
/// eg. `key`, `key[]`, `key[arg]`, `key[arg[abc]]`
///
/// Values may be unquoted (therefore no spaces) or single-quoted.
/// Single quotes in a quoted value may be backslash-escaped.
/// eg. `x`, `'x y'`, `'x y\'s'`
///
/// <records> ::= " "* <rr>* " "*
///      <rr> ::= <r> | <r> <rr>
///       <r> ::= <pk> | <kv>
///      <pk> ::= <u> | <u> "[" <a> "]" <u>
///      <kv> ::= <k> "=" <v>
///       <k> ::= <u> | <u> "[" <a> "]"
///       <v> ::= "'" <q> "'" | <u>
///       <q> ::= <all octets except "'" unless immediately preceded by "\">
///       <u> ::= <all octets except " ">
///       <a> ::= <all octets until "]" without an unique preceeding "[">
///
library DNSTXTParserLib {
    /// @dev The DFA internal states.
    enum State {
        START,
        IGNORED_KEY,
        IGNORED_KEY_ARG,
        VALUE,
        QUOTED_VALUE,
        UNQUOTED_VALUE,
        IGNORED_VALUE,
        IGNORED_QUOTED_VALUE,
        IGNORED_UNQUOTED_VALUE
    }

    /// @dev The codepoint for the `\` character.
    bytes1 private constant CH_BACKSLASH = bytes1(0x5C);
    /// @dev The codepoint for the `'` character.
    bytes1 private constant CH_QUOTE = "'";
    /// @dev The codepoint for the ` ` character.
    bytes1 private constant CH_SPACE = " ";
    /// @dev The codepoint for the `=` character.
    bytes1 private constant CH_EQUAL = "=";
    /// @dev The codepoint for the `[` character.
    bytes1 private constant CH_ARG_OPEN = "[";
    /// @dev The codepoint for the `]` character.
    bytes1 private constant CH_ARG_CLOSE = "]";

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @dev Implements a DFA to parse the text record, looking for an entry matching `key`.
    /// @param data The text record to parse.
    /// @param key The exact key to search for with trailing equals, eg. "key=".
    /// @return value The value if found, or an empty string if `key` does not exist.
    function find(bytes memory data, bytes memory key) internal pure returns (bytes memory value) {
        // Here we use a simple state machine to parse the text record. We
        // process characters one at a time; each character can trigger a
        // transition to a new state, or terminate the DFA and return a value.
        // For states that expect to process a number of tokens, we use
        // inner loops for efficiency reasons, to avoid the need to go
        // through the outer loop and switch statement for every character.
        State state = State.START;
        uint256 len = data.length;
        for (uint256 i; i < len; ) {
            if (state == State.START) {
                // look for the start of a key
                while (i < len && data[i] == CH_SPACE) {
                    ++i; // eat whitespace
                }
                if (i + key.length > len) {
                    break; // key doesn't fit in the remaining data
                } else if (BytesUtils.equals(data, i, key, 0, key.length)) {
                    i += key.length;
                    state = State.VALUE; // found key, parse its value
                } else {
                    state = State.IGNORED_KEY; // different key, skip value
                }
            } else if (state == State.IGNORED_KEY) {
                // look for the end of the key
                while (i < len) {
                    bytes1 cp = data[i++];
                    if (cp == CH_EQUAL) {
                        state = State.IGNORED_VALUE; // ignore its value
                        break;
                    } else if (cp == CH_ARG_OPEN) {
                        state = State.IGNORED_KEY_ARG; // key has arg, ignore its arg
                        break;
                    } else if (cp == CH_SPACE) {
                        state = State.START; // there is no value => continue searching
                        break;
                    }
                }
            } else if (state == State.IGNORED_KEY_ARG) {
                // look for the end of the key arg
                uint256 depth;
                for (; i < len; ++i) {
                    if (data[i] == CH_ARG_OPEN) {
                        ++depth;
                    } else if (data[i] == CH_ARG_CLOSE) {
                        if (depth == 0) {
                            ++i; // parsed key[arg]
                            if (i < len && data[i] == CH_EQUAL) {
                                state = State.IGNORED_VALUE; // ignore its value
                                ++i;
                            } else {
                                // this is recoverable parsing error
                                state = State.IGNORED_UNQUOTED_VALUE; // assume unquoted and ignore its value
                            }
                            break;
                        } else {
                            --depth;
                        }
                    }
                }
            } else if (state == State.VALUE) {
                // determine type of value to parse
                if (data[i] == CH_QUOTE) {
                    state = State.QUOTED_VALUE; // there was a quote, so "quoted"
                    ++i;
                } else {
                    state = State.UNQUOTED_VALUE; // everything else is unquoted
                }
            } else if (state == State.QUOTED_VALUE) {
                // parse the quoted value
                uint256 n; // unescaped length
                for (uint256 j = i; i < len; ++n) {
                    bytes1 cp = data[i++]; // look for quote or escape
                    if (cp == CH_QUOTE) {
                        value = new bytes(n); // unescaped quote is end of value
                        for (i = 0; i < n; ++i) {
                            cp = data[j++]; // raw byte
                            if (cp == CH_BACKSLASH) {
                                cp = data[j++]; // Process escaped byte
                            }
                            value[i] = cp;
                        }
                        return value; // unescaped and unquoted
                    } else if (cp == CH_BACKSLASH) {
                        ++i; // escape, so skip a byte
                    }
                }
            } else if (state == State.UNQUOTED_VALUE) {
                // parse the unquoted value
                for (uint256 j = i; j < len; ++j) {
                    if (data[j] == CH_SPACE) {
                        len = j; // space is end of value
                    }
                }
                return BytesUtils.substring(data, i, len - i);
            } else if (state == State.IGNORED_VALUE) {
                // determine type of value to ignore
                if (data[i] == CH_QUOTE) {
                    state = State.IGNORED_QUOTED_VALUE; // there was a quote, so "quoted"
                    ++i;
                } else {
                    state = State.IGNORED_UNQUOTED_VALUE; // everything else is unquoted
                }
            } else if (state == State.IGNORED_QUOTED_VALUE) {
                // ignore the quoted value
                while (i < len) {
                    bytes1 cp = data[i++]; // look for quote or escape
                    if (cp == CH_QUOTE) {
                        break; // unescaped quote is end of value
                    } else if (cp == CH_BACKSLASH) {
                        ++i; // escape, so skip a byte
                    }
                }
                state = State.START; // => continue searching
            } else {
                // assert(state == State.IGNORED_UNQUOTED_VALUE);
                // ignore unquoted value
                if (data[i] == CH_SPACE) {
                    state = State.START; // space is end of value => continue searching
                }
                ++i;
            }
        }
    }
}
