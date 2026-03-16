// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {DNSTXTParserLib} from "~src/dns/libraries/DNSTXTParserLib.sol";

contract DNSTXTParserLibTest is Test {
    function test_find_whitespace() external pure {
        assertEq(DNSTXTParserLib.find("", "a="), "");
        assertEq(DNSTXTParserLib.find("  ", "a="), "");
        assertEq(DNSTXTParserLib.find("a=1  ", "a="), "1");
        assertEq(DNSTXTParserLib.find(" a=2 ", "a="), "2");
        assertEq(DNSTXTParserLib.find("  a=3", "a="), "3");
    }

    function test_find_balancedSquareBrackets() external pure {
        assertEq(DNSTXTParserLib.find("a[[]]=1", "a[[]]="), "1");
        assertEq(DNSTXTParserLib.find("a[b[]]=2", "a[b[]]="), "2");
        assertEq(DNSTXTParserLib.find("a[b[c]]=3", "a[b[c]]="), "3");
        assertEq(DNSTXTParserLib.find("a[[b]]=4", "a[[b]]="), "4");
    }

    function test_find_unbalancedSquareBrackets() external pure {
        assertEq(DNSTXTParserLib.find("a[[]=1", "a[]="), "");
        assertEq(DNSTXTParserLib.find("a[]]=2", "a[]="), "");
        assertEq(DNSTXTParserLib.find("a[[[=3", "a[]="), "");
        assertEq(DNSTXTParserLib.find("a[]]=4 a[]=1", "a[]="), "1");
    }

    function test_find_ignored() external pure {
        assertEq(DNSTXTParserLib.find("a a=1", "a="), "1");
        assertEq(DNSTXTParserLib.find("a[b] a=2", "a="), "2");
        assertEq(DNSTXTParserLib.find("a[b]junk a=3", "a="), "3");
        assertEq(DNSTXTParserLib.find("a[b]' a=4", "a="), "4");
        assertEq(DNSTXTParserLib.find("a' a=5", "a="), "5");
        assertEq(DNSTXTParserLib.find("' a=6", "a="), "6");
        assertEq(DNSTXTParserLib.find("a['] a=7", "a="), "7");
        assertEq(DNSTXTParserLib.find("a[''] a=8", "a="), "8");
    }

    function test_find_unquoted() external pure {
        assertEq(DNSTXTParserLib.find("a=1", "a="), "1");
        assertEq(DNSTXTParserLib.find("bb=2", "bb="), "2");
        assertEq(DNSTXTParserLib.find("c[]=3", "c[]="), "3");
    }

    function test_find_unquotedWithArg() external pure {
        assertEq(DNSTXTParserLib.find("a=1 a[b]=1", "a[b]="), "1");
        assertEq(DNSTXTParserLib.find("a=1 a[bb]=2", "a[bb]="), "2");
        assertEq(DNSTXTParserLib.find("a=a[b] a[b]=3", "a[b]="), "3");
    }

    function test_find_quoted() external pure {
        assertEq(DNSTXTParserLib.find("a='b=X' b=1", "b="), "1");
        assertEq(DNSTXTParserLib.find("a='a[b]=X' a[b]=2", "a[b]="), "2");
        assertEq(DNSTXTParserLib.find("a='\\' a[d]=X' a[d]='3'", "a[d]="), "3");
        assertEq(DNSTXTParserLib.find("a='\\'\\'\\'\\''", "a="), "''''");
    }

    function test_find_quotedWithoutGap() external pure {
        assertEq(DNSTXTParserLib.find("a='X'b='1'", "b="), "1");
    }

    function test_find_quotedWithoutClose() external pure {
        assertEq(DNSTXTParserLib.find("a=' a=2", "a="), "");
    }
}
