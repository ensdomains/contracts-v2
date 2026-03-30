// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {LibHalving} from "~src/registrar/libraries/LibHalving.sol";

contract LibHalvingTest is Test {
    function test_halving_pow2() external pure {
        for (uint256 i; i < 256; i++) {
            assertEq(LibHalving.halving(1 << 255, 1, i), 1 << (255 - i));
        }
    }

    function _assertNear(uint256 value, uint256 expect, uint256 exact, uint256 tol) internal pure {
        assertEq(value, expect, "same");
        uint256 diff = expect > exact ? expect - exact : exact - expect;
        if (diff > 0) {
            assertLt((exact + diff - 1) / diff, 10 ** uint256(tol), "error");
        }
    }

    function test_halving_computed() external pure {
        _assertNear(LibHalving.halving(1424499730, 8906, 139967), 26462, 26465, 4);
        _assertNear(LibHalving.halving(25448394752, 3120, 28344), 46872731, 46872559, 6);
        _assertNear(LibHalving.halving(226801697741, 2055, 7691), 16944188740, 16944070054, 6);
        _assertNear(LibHalving.halving(8346969424321, 2447, 14567), 134739948345, 134739878463, 7);
        _assertNear(LibHalving.halving(45287518154421, 3882, 57451), 1588328639, 1588313410, 6);
        _assertNear(
            LibHalving.halving(570920124541253, 9882, 107044),
            313151078238,
            313149809990,
            6
        );
        _assertNear(
            LibHalving.halving(7645843420289247, 2217, 5130),
            1537665107975056,
            1537661454800508,
            6
        );
        _assertNear(
            LibHalving.halving(41496322237742742, 9631, 138777),
            1906996964267,
            1906978706870,
            6
        );
        _assertNear(
            LibHalving.halving(324922745063857570, 3699, 14160),
            22878240879739585,
            22878035801573052,
            6
        );
        _assertNear(
            LibHalving.halving(7160344361217578864, 376, 2562),
            63645461810911484,
            63645361554348369,
            6
        );
        _assertNear(
            LibHalving.halving(48224578080290028571, 4891, 37054),
            252744870505318051,
            252742620367330313,
            6
        );
        _assertNear(
            LibHalving.halving(105105524861191541746, 6259, 54700),
            245923975222518136,
            245923149907088301,
            6
        );
        _assertNear(
            LibHalving.halving(3099396934116196421933, 3511, 31839),
            5773426072293995295,
            5773376140217802275,
            6
        );
        _assertNear(
            LibHalving.halving(26362372193702182792471, 4465, 32623),
            166549977597448035667,
            166549775208987485845,
            6
        );
        _assertNear(
            LibHalving.halving(990909067413969805326317, 301, 3338),
            454678187455967549808,
            454675088014747167270,
            6
        );
        _assertNear(
            LibHalving.halving(3381740391629922203681908, 715, 10038),
            200878650042027568241,
            200877705112613028527,
            6
        );
        _assertNear(
            LibHalving.halving(20690080805932031152205220, 7464, 53584),
            142781580193629410427449,
            142780897151513340316761,
            6
        );
        _assertNear(
            LibHalving.halving(997325693508064282098634698, 5823, 79101),
            81203875465712359043529,
            81203514400252740888790,
            6
        );
        _assertNear(
            LibHalving.halving(6654406976005663001193755017, 8615, 128040),
            223392455824911265372939,
            223391340970344010446350,
            6
        );
        _assertNear(
            LibHalving.halving(63990819057295833822937117138, 5696, 9367),
            20468132231412279313226604986,
            20468105475107205357583938901,
            6
        );
        _assertNear(
            LibHalving.halving(944431998705134667255602102406, 7559, 79787),
            627671476720048668608848886,
            627666858068998984730219320,
            6
        );
    }
}
