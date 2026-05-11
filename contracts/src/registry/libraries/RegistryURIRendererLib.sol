// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {StringUtils} from "@ens/contracts/utils/StringUtils.sol";

import {LibString} from "../../utils/LibString.sol";

library RegistryURIRendererLib {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    struct Data {
        string label;
        string canonicalName;
    }

    ////////////////////////////////////////////////////////////////////////
    // Library Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Create JSON metadata URI string.
    /// @param data The metadata.
    /// @return The data URI.
    function metadataURI(RegistryURIRendererLib.Data memory data)
        public
        pure
        returns (string memory)
    {
        string memory fqdn = data.label;
        if (bytes(data.canonicalName).length > 0) {
            fqdn = string.concat(data.label, ".", data.canonicalName);
        }
        return
            string.concat(
                "data:application/json;{\"name\":\"",
                StringUtils.escape(fqdn),
                "\",\"image\":\"",
                imageURI(data),
                "\",\"attributes\":[",
                createAttribute(
                    "Length",
                    "number",
                    LibString.toString(StringUtils.strlen(data.label))
                ),
                ",",
                createAttribute("Bytes", "number", LibString.toString(bytes(data.label).length)),
                "]}"
            );
    }

    /// @notice Create SVG image URI string.
    /// @param data The metadata.
    /// @return The data URI.
    function imageURI(Data memory data) public pure returns (string memory) {
        return string.concat("data:image/svg+xml;base64,", toBase64(imageSVG(data)));
    }

    /// @notice Create SVG image data string.
    /// @param data The metadata.
    /// @return The SVG data.
    function imageSVG(Data memory data) public pure returns (string memory) {
        return
            string.concat(
                "<svg width=\"270\" height=\"270\" viewBox=\"0 0 270 270\" fill=\"none\" xmlns=\"http://www.w3.org/2000/svg\">",
                "<text>",
                data.label,
                "</text>",
                "</svg>"
            );
    }

    function createAttribute(
        string memory traitType,
        string memory displayType,
        string memory literalValue
    )
        internal
        pure
        returns (string memory json)
    {
        json = string.concat("{\"trait_type\":\"", traitType, "\"");
        if (bytes(displayType).length > 0) {
            json = string.concat(",\"display_type\":\"", displayType, "\"");
        }
        json = string.concat(",\"value\":", literalValue, "}");
    }

    function toBase64(string memory s) internal pure returns (string memory) {
        return s;
    }
}
// https://metadata.ens.domains/mainnet/0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85/0xcb0cbc8493baf4a7b1972914ba0be89040e56e4a3c98d60268fe37b8c8e546d9
// {
//   "is_normalized": true,
//   "name": "raffy.eth",
//   "description": "raffy.eth, an ENS name.",
//   "attributes": [
//     {
//       "trait_type": "Created Date",
//       "display_type": "date",
//       "value": 1578718860000
//     },
//     {
//       "trait_type": "Length",
//       "display_type": "number",
//       "value": 5
//     },
//     {
//       "trait_type": "Segment Length",
//       "display_type": "number",
//       "value": 5
//     },
//     {
//       "trait_type": "Character Set",
//       "display_type": "string",
//       "value": "letter"
//     },
//     {
//       "trait_type": "Registration Date",
//       "display_type": "date",
//       "value": 1620782051000
//     },
//     {
//       "trait_type": "Expiration Date",
//       "display_type": "date",
//       "value": 2031022427000
//     }
//   ],
//   "url": "https://app.ens.domains/name/raffy.eth",
//   "last_request_date": 1778454402571,
//   "version": 0,
//   "background_image": "https://metadata.ens.domains/mainnet/avatar/raffy.eth",
//   "image": "https://metadata.ens.domains/mainnet/0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85/0xcb0cbc8493baf4a7b1972914ba0be89040e56e4a3c98d60268fe37b8c8e546d9/image",
//   "image_url": "https://metadata.ens.domains/mainnet/0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85/0xcb0cbc8493baf4a7b1972914ba0be89040e56e4a3c98d60268fe37b8c8e546d9/image"
// }
