pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";

library LibValidator {
    using SafeMath for uint256;
    using SafeMath for uint64;

    string public constant DOMAIN_NAME = "Orion Exchange";
    string public constant DOMAIN_VERSION = "1";
    uint256 public constant CHAIN_ID = 666;
    bytes32
        public constant DOMAIN_SALT = 0xf2d857f4a3edcb9b78b4d503bfe733db1e3f6cdc2b7971ee739626c97e86a557;

    bytes32 public constant EIP712_DOMAIN_TYPEHASH = keccak256(
        abi.encodePacked(
            "EIP712Domain(string name,string version,uint256 chainId,bytes32 salt)"
        )
    );
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        abi.encodePacked(
            "Order(address senderAddress,address matcherAddress,address baseAsset,address quoteAsset,address matcherFeeAsset,uint64 amount,uint64 price,uint64 matcherFee,uint64 nonce,uint64 expiration,uint8 buySide)"
        )
    );

    bytes32 public constant DOMAIN_SEPARATOR = keccak256(
        abi.encode(
            EIP712_DOMAIN_TYPEHASH,
            keccak256(bytes(DOMAIN_NAME)),
            keccak256(bytes(DOMAIN_VERSION)),
            CHAIN_ID,
            DOMAIN_SALT
        )
    );

    struct Order {
        address senderAddress;
        address matcherAddress;
        address baseAsset;
        address quoteAsset;
        address matcherFeeAsset;
        uint64 amount;
        uint64 price;
        uint64 matcherFee;
        uint64 nonce;
        uint64 expiration;
        uint8 buySide; // buy or sell
        bytes signature;
    }

    function validateV3(Order memory order) public pure returns (bool) {
        bytes32 domainSeparator = DOMAIN_SEPARATOR;

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                getTypeValueHash(order)
            )
        );

        if (order.signature.length != 65) {
            revert("ECDSA: invalid signature length");
        }

        // Divide the signature in r, s and v variables
        bytes32 r;
        bytes32 s;
        uint8 v;

        bytes memory signature = order.signature;

        // ecrecover takes the signature parameters, and the only way to get them
        // currently is to use assembly.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        if (
            uint256(s) >
            0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
        ) {
            revert("ECDSA: invalid signature 's' value");
        }

        if (v != 27 && v != 28) {
            revert("ECDSA: invalid signature 'v' value");
        }

        return ecrecover(digest, v, r, s) == order.senderAddress;
    }

    function getTypeValueHash(Order memory _order)
        internal
        pure
        returns (bytes32)
    {
        bytes32 orderTypeHash = ORDER_TYPEHASH;

        return
            keccak256(
                abi.encode(
                    orderTypeHash,
                    _order.senderAddress,
                    _order.matcherAddress,
                    _order.baseAsset,
                    _order.quoteAsset,
                    _order.matcherFeeAsset,
                    _order.amount,
                    _order.price,
                    _order.matcherFee,
                    _order.nonce,
                    _order.expiration,
                    _order.buySide
                )
            );
    }

    function checkOrdersInfo(
        Order memory buyOrder,
        Order memory sellOrder,
        address sender,
        uint256 filledAmount,
        uint256 filledPrice,
        uint256 currentTime
    ) public pure returns (bool success) {
        require(validateV3(buyOrder), "E2");
        require(validateV3(sellOrder), "E2");

        // Same matcher address
        require(
            buyOrder.matcherAddress == sender &&
                sellOrder.matcherAddress == sender,
            "E3"
        );

        // Check matching assets
        require(
            buyOrder.baseAsset == sellOrder.baseAsset &&
                buyOrder.quoteAsset == sellOrder.quoteAsset,
            "E3"
        );

        // Check order amounts
        require(filledAmount <= buyOrder.amount, "E3");
        require(filledAmount <= sellOrder.amount, "E3");

        // Check Price values
        require(filledPrice <= buyOrder.price, "E3");
        require(filledPrice >= sellOrder.price, "E3");

        // Check Expiration Time. Convert to seconds first
        require(buyOrder.expiration.div(1000) >= currentTime, "E4");
        require(sellOrder.expiration.div(1000) >= currentTime, "E4");

        require( buyOrder.buySide==1 && sellOrder.buySide==0, "EX");
        success = true;
    }
}
