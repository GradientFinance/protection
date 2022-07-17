// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "solmate/tokens/ERC721.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/utils/Strings.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import {
    OrderType,
    BasicOrderType,
    ItemType,
    Side
} from "./ConsiderationEnums.sol";

import {OrderParameters, Order, OfferItem, ConsiderationItem} from "./ConsiderationStructs.sol";

error NonExistentTokenURI();
error WithdrawTransfer();
error ProtectionNotExpired();
error CollateralNotLiquidated();

interface NFTfi {
    function loanRepaidOrLiquidated(uint32) external view returns (bool);
    function loanIdToLoan(uint32) external returns (
        uint256 loanPrincipalAmount,
        uint256 maximumRepaymentAmount,
        uint256 nftCollateralId,
        address loanERC20Denomination,
        uint32 loanDuration,
        uint16 loanInterestRateForDurationInBasisPoints,
        uint16 loanAdminFeeInBasisPoints,
        address nftCollateralWrapper,
        uint64 loanStartTime,
        address nftCollateralContract,
        address borrower
    );
}

/**
 * @title Gradient Protection (v0.1) contract
 * @author @cairoeth
 * @dev ERC721 contract from which NFTs are minted to represent loan protection.
 **/
contract Protection is ERC721, Ownable, ReentrancyGuard, ERC721TokenReceiver {
    using Strings for uint256;
    string public baseURI = "";
    address payee;
    address nftfiAddress;
    uint256 internal globalSalt;

    NFTfi NFTfiContract = NFTfi(nftfiAddress);

    mapping(uint32 => uint256) private stake;
    mapping(uint32 => uint32) private lowerBound;
    mapping(uint32 => uint32) private upperBound;
    mapping(uint32 => uint256) private liquidationValue;
    mapping(uint32 => bool) private liquidationStatus;
    mapping(string => uint32) private collateralToProtection;

    // Declaring Seaport structure objects
    OfferItem[] _offerItem;
    ConsiderationItem[] _considerationItem;
    OrderParameters _orderParameters;
    Order _order;

    constructor(address nftfi) ERC721("Gradient Protection", "PROTECTION") {
        payee = msg.sender;
        nftfiAddress = nftfi;
    }

    function toAsciiString(address x) internal pure returns (string memory) {
        bytes memory s = new bytes(40);
        for (uint i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint(uint160(x)) / (2**(8*(19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2*i] = char(hi);
            s[2*i+1] = char(lo);            
        }
        return string(s);
    }

    function char(bytes1 b) internal pure returns (bytes1 c) {
        if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
        else return bytes1(uint8(b) + 0x57);
    }

    /**
    * @dev Mints ERC721 token that represents loan protection
    * @param recipient is the receiver address of the protection (lender)
    * @param nftfiId is the id of the NFTfi Promissory Note
    **/
    function _mintProtection(address recipient, uint32 nftfiId, uint32 lowerBoundvalue, uint32 upperBoundvalue) public payable onlyOwner {
        /// msg.value value is amount of funds staked to cover the protection in case of default
        _safeMint(recipient, nftfiId);
        stake[nftfiId] = msg.value;
        lowerBound[nftfiId] = lowerBoundvalue;
        upperBound[nftfiId] = upperBoundvalue;
        address collateralContract;
        uint collateralId;
        collateralToProtection[string(abi.encodePacked(toAsciiString(collateralContract),'',Strings.toString(collateralId)))] = nftfiId;
    }

    /**
    * @dev Returns the URL of a token's metadata
    * @param tokenId is the token id
    **/
    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        if (ownerOf(tokenId) == address(0)) {
            revert NonExistentTokenURI();
        }
        return
            bytes(baseURI).length > 0
                ? string(abi.encodePacked(baseURI, tokenId.toString()))
                : "";
    }

    /**
    * @dev Sets the NFTfi address
    * @param _address is the NFTfi main smart contract address
    **/
    function _setNFTfiAddress(address _address) external onlyOwner {
       nftfiAddress = _address;
    }

    /**
    * @notice Activates the protection after loan reaches maturity
    * @param nftfiId is the id of the NFTfi Promissory Note/protection NFT 
    **/
    function _activateProtection(uint32 nftfiId) external nonReentrant {
        /// Require NFT protection not to be burned
        require(_ownerOf[nftfiId] != address(0), "Protection does not exist");

        /// Closes a expired protection when the borrower payed back or when the lender wants to keep the collateral
        if (NFTfiContract.loanRepaidOrLiquidated(nftfiId) && liquidationValue[nftfiId] == 0 && !liquidationStatus[nftfiId]) {
            _burn(nftfiId);
            (bool transferTx, ) = payee.call{value: stake[nftfiId]}("");
            if (!transferTx) {
                revert WithdrawTransfer();
            }
            stake[nftfiId] = 0;
        }
        /// Closes a protection after the collateral has been liquidated by covering any losses
        else if  (NFTfiContract.loanRepaidOrLiquidated(nftfiId) && liquidationValue[nftfiId] > 0 && liquidationStatus[nftfiId]) {
            /// Option A: The collateral is liquidated at a price above the upper-bound of the protection 
            if (liquidationValue[nftfiId] > upperBound[nftfiId]) {
                _burn(nftfiId);
                /// Return all $ from the liquidation to protection owner
                (bool transferTx1, ) = _ownerOf[nftfiId].call{value: liquidationValue[nftfiId]}("");
                if (!transferTx1) {
                    revert WithdrawTransfer();
                }
                /// Return stake
                (bool transferTx2, ) = payee.call{value: stake[nftfiId]}("");
                if (!transferTx2) {
                    revert WithdrawTransfer();
                }
                stake[nftfiId] = 0;
            }
            /// Option B: The collateral is liquidated at a price between the bounds of the protection
            else if (lowerBound[nftfiId] < liquidationValue[nftfiId] && liquidationValue[nftfiId] < upperBound[nftfiId]) {
                _burn(nftfiId);
                uint256 losses = upperBound[nftfiId] - liquidationValue[nftfiId];
                stake[nftfiId] - losses;
                /// Return all $ from the liquidation to protection owner and cover lossses
                (bool transferTx1, ) = _ownerOf[nftfiId].call{value: liquidationValue[nftfiId] + losses}("");
                if (!transferTx1) {
                    revert WithdrawTransfer();
                }
                /// Return remaining stake, if any.
                (bool transferTx2, ) = payee.call{value: stake[nftfiId]}("");
                if (!transferTx2) {
                    revert WithdrawTransfer();
                }
            }
            /// Option C: The collateral is liquidated at a price below the lower-bound of the protection
            else if (liquidationValue[nftfiId] < lowerBound[nftfiId]) {
                _burn(nftfiId);
                /// Return all $ from the liquidation and protection to protection owner
                (bool transferTx, ) = _ownerOf[nftfiId].call{value: liquidationValue[nftfiId] + stake[nftfiId]}("");
                if (!transferTx) {
                    revert WithdrawTransfer();
                }
                stake[nftfiId] = 0;
            }
            /// Collateral liquidation is activate and but not sold yet
            else if (NFTfiContract.loanRepaidOrLiquidated(nftfiId) && liquidationStatus[nftfiId]) {
                revert CollateralNotLiquidated();
            }
        }
        else {
            revert ProtectionNotExpired();
        }
    }

    /**
    * @dev Liquidation executed by the lender when the borrower defaults and the lender wants to cover any losses.
    **/
    function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenId,
        bytes calldata
    ) external override virtual returns (bytes4) {
        uint32 nftfiId = collateralToProtection[string(abi.encodePacked(toAsciiString(msg.sender),'',Strings.toString(_tokenId)))];
        require(_ownerOf[nftfiId] != address(0), "Protection does not exist");

        /// liquidate nft with a dutch auction through seaport

        /**
         *   ========= OfferItem ==========
         *   ItemType itemType;
         *   address token;
         *   uint256 identifierOrCriteria;
         *   uint256 startAmount;
         *   uint256 endAmount;
         */
        _offerItem = OfferItem(
            ItemType.ERC721, 
            msg.sender, 
            _tokenId, 
            1, 
            1
        );

        /**
         *   ========= ConsiderationItem ==========
         *   ItemType itemType;
         *   address token;
         *   uint256 identifierOrCriteria;
         *   uint256 startAmount;
         *   uint256 endAmount;
         *   address payable recipient;
         */
        _considerationItem = ConsiderationItem(
            ItemType.NATIVE,
            address(0),
            0,
            150000000000000000000,
            0,
            payable(address(this))
        );

        /**
         *   ========= OrderParameters ==========
         *   address offerer;
         *   address zone;
         *   struct OfferItem[] offer;
         *   struct ConsiderationItem[] consideration;
         *   enum OrderType orderType;
         *   uint256 startTime;
         *   uint256 endTime;
         *   bytes32 zoneHash;
         *   uint256 salt;
         *   bytes32 conduitKey;
         *   uint256 totalOriginalConsiderationItems;
         */
        _orderParameters = OrderParameters(
            address(this), 
            address(0),
            _offerItem,
            _considerationItem,
            OrderType.FULL_RESTRICTED,
            block.timestamp,
            block.timestamp + 1 days,
            bytes32(0),
            globalSalt++,
            bytes32(0),
            1
        );

        // EIP 1271 Signature

        /**
         *   ========= Order ==========
         *   struct OrderParameters parameters;
         *   bytes signature;
         */
        // _order = Order(_orderParameters);

        liquidationStatus[nftfiId] = true;
        return ERC721TokenReceiver.onERC721Received.selector;
    }
}
