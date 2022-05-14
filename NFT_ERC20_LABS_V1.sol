// SPDX-License-Identifier: MIT
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./NonblockingReceiver.sol";
import "./ClampedRandomizer.sol";

pragma solidity ^0.8.10;

contract HuntersOfEvil is
    ERC721Enumerable,
    ERC721URIStorage,
    IERC2981,
    Pausable,
    Ownable,
    ERC721Burnable,
    NonblockingReceiver,
    ClampedRandomizer
{
    modifier onlyDevs() {
        require(
            devFees[msg.sender].percent > 0,
            "Dev Only: caller is not the developer"
        );
        _;
    }

    event WithdrawFees(address indexed devAddress, uint256 amount);
    event WithdrawWrongTokens(
        address indexed devAddress,
        address tokenAddress,
        uint256 amount
    );
    event WithdrawWrongNfts(
        address indexed devAddress,
        address tokenAddress,
        uint256 tokenId
    );
    event Migration(address indexed _to, uint256 indexed _tokenId);

    using SafeMath for uint256;
    using Address for address;

    address public royaltyAddress = 0xA6F29Ab1Bf8c731Bc99E5CBacDF4F46409BABa49;

    IERC20 public erc20Token;

    string public baseURI;
    string public baseExtension = ".json";

    // VARIABLES
    uint256 public maxSupply = 777;
    uint256 public maxPerTx = 5;
    uint256 public maxPerPerson = 777;
    uint256 public price = 25;
    uint256 private gasForDestinationLzReceive = 350000;

    uint256 public royalty = 750;
    // COLLECTED FESS
    struct DevFee {
        uint256 percent;
        uint256 amount;
    }
    mapping(address => DevFee) public devFees;
    address[] private devList;

    bool public whitelistedOnly = true;
    mapping(address => uint256) public whiteListed;

    constructor(
        IERC20 _erc20Token,
        address[] memory _devList,
        uint256[] memory _fees,
        address _lzEndpoint
    ) ERC721("Hunters Of Evil", "HOE") ClampedRandomizer(maxSupply) {
        require(_devList.length == _fees.length, "Error: invalid data");
        uint256 totalFee = 0;
        for (uint8 i = 0; i < _devList.length; i++) {
            devList.push(_devList[i]);
            devFees[_devList[i]] = DevFee(_fees[i], 0);
            totalFee += _fees[i];
        }
        require(totalFee == 10000, "Error: invalid total fee");
        endpoint = ILayerZeroEndpoint(_lzEndpoint);
        erc20Token = _erc20Token;
        _pause();
    }

    // This function transfers the nft from your address on the
    // source chain to the same address on the destination chain
    function traverseChains(uint16 _chainId, uint256 tokenId) public payable {
        require(
            msg.sender == ownerOf(tokenId),
            "You must own the token to traverse"
        );
        require(
            trustedRemoteLookup[_chainId].length > 0,
            "This chain is currently unavailable for travel"
        );

        // burn NFT, eliminating it from circulation on src chain
        _burn(tokenId);

        // abi.encode() the payload with the values to send
        bytes memory payload = abi.encode(msg.sender, tokenId);

        // encode adapterParams to specify more gas for the destination
        uint16 version = 1;
        bytes memory adapterParams = abi.encodePacked(
            version,
            gasForDestinationLzReceive
        );

        // get the fees we need to pay to LayerZero + Relayer to cover message delivery
        // you will be refunded for extra gas paid
        (uint256 messageFee, ) = endpoint.estimateFees(
            _chainId,
            address(this),
            payload,
            false,
            adapterParams
        );

        require(
            msg.value >= messageFee,
            "Error: msg.value not enough to cover messageFee. Send gas for message fees"
        );

        endpoint.send{value: msg.value}(
            _chainId, // destination chainId
            trustedRemoteLookup[_chainId], // destination address of nft contract
            payload, // abi.encoded()'ed bytes
            payable(msg.sender), // refund address
            address(0x0), // 'zroPaymentAddress' unused for this
            adapterParams // txParameters
        );
    }

    // just in case this fixed variable limits us from future integrations
    function setGasForDestinationLzReceive(uint256 newVal) external onlyOwner {
        gasForDestinationLzReceive = newVal;
    }

    function _LzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) internal override {
        // decode
        (address toAddr, uint256 tokenId) = abi.decode(
            _payload,
            (address, uint256)
        );

        // mint the tokens back into existence on destination chain
        _safeMint(toAddr, tokenId);
    }

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    function splitFees(uint256 sentAmount) internal {
        for (uint8 i = 0; i < devList.length; i++) {
            address devAddress = devList[i];
            uint256 devFee = devFees[devAddress].percent;
            uint256 devFeeAmount = sentAmount.mul(devFee).div(10000);
            devFees[devAddress].amount += devFeeAmount;
        }
    }

    function mint(uint256 amount) public whenNotPaused {
        uint256 supply = totalSupply();
        require(amount > 0 && amount <= maxPerTx, "Error: max par tx limit");
        require(
            balanceOf(msg.sender) + 1 <= maxPerPerson,
            "Error: max per address limit"
        );

        uint256 totalAmount = price.mul(amount);

        require(
            erc20Token.allowance(msg.sender, address(this)) >= totalAmount,
            "Error: invalid price"
        );
        require(
            supply + amount - 1 < maxSupply,
            "Error: cannot mint more than total supply"
        );

        if (whitelistedOnly)
            require(
                whiteListed[msg.sender] >= amount,
                "Error: you are not whitelisted or amount is higher than limit"
            );

        erc20Token.transferFrom(msg.sender, address(this), totalAmount);

        for (uint256 i = 0; i < amount; i++) {
            internalMint(msg.sender);
            if (whitelistedOnly) whiteListed[msg.sender] -= 1;
        }

        splitFees(totalAmount);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function Owned(address _owner) external view returns (uint256[] memory) {
        uint256 tokenCount = balanceOf(_owner);
        if (tokenCount == 0) {
            return new uint256[](0);
        } else {
            uint256[] memory result = new uint256[](tokenCount);
            uint256 index;
            for (index = 0; index < tokenCount; index++) {
                result[index] = tokenOfOwnerByIndex(_owner, index);
            }
            return result;
        }
    }

    function tokenExists(uint256 _id) external view returns (bool) {
        return (_exists(_id));
    }

    function royaltyInfo(uint256, uint256 _salePrice)
        external
        view
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        return (royaltyAddress, (_salePrice * royalty) / 10000);
    }

    //dev

    function whiteList(address[] memory _addressList, uint256 count)
        external
        onlyOwner
    {
        require(_addressList.length > 0, "Error: list is empty");

        for (uint256 i = 0; i < _addressList.length; i++) {
            require(_addressList[i] != address(0), "Address cannot be 0.");
            whiteListed[_addressList[i]] = count;
        }
    }

    function removeWhiteList(address[] memory addressList) external onlyOwner {
        require(addressList.length > 0, "Error: list is empty");
        for (uint256 i = 0; i < addressList.length; i++)
            whiteListed[addressList[i]] = 0;
    }

    function updateWhitelistStatus() external onlyOwner {
        whitelistedOnly = !whitelistedOnly;
    }

    function updatePausedStatus() external onlyOwner {
        paused() ? _unpause() : _pause();
    }

    function setMaxPerPerson(uint256 newMaxBuy) external onlyOwner {
        maxPerPerson = newMaxBuy;
    }

    function setMaxPerTx(uint256 newMaxBuy) external onlyOwner {
        maxPerTx = newMaxBuy;
    }

    function setBaseURI(string memory newBaseURI) external onlyOwner {
        baseURI = newBaseURI;
    }

    function setPrice(uint256 newPrice) external onlyOwner {
        price = newPrice;
    }

    function setERC20Token(IERC20 newToken) external onlyOwner {
        erc20Token = newToken;
    }

    function setURI(uint256 tokenId, string memory uri) external onlyOwner {
        _setTokenURI(tokenId, uri);
    }

    function setRoyalty(uint16 _royalty) external onlyOwner {
        require(_royalty >= 0, "Royalty must be greater than or equal to 0%");
        require(
            _royalty <= 750,
            "Royalty must be greater than or equal to 7,5%"
        );
        royalty = _royalty;
    }

    function setRoyaltyAddress(address _royaltyAddress) external onlyOwner {
        royaltyAddress = _royaltyAddress;
    }

    //Overrides

    function internalMint(address to) internal {
        uint256 tokenId = _genClampedNonce();
        _safeMint(to, tokenId);
    }

    function safeMint(address to) public onlyOwner {
        internalMint(to);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IERC2981).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override(ERC721, ERC721Enumerable) whenNotPaused {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function _burn(uint256 tokenId)
        internal
        override(ERC721, ERC721URIStorage)
    {
        super._burn(tokenId);
    }

    /// @dev withdraw fees
    function withdraw() external onlyDevs {
        uint256 amount = devFees[msg.sender].amount;
        require(amount > 0, "Error: no fees :(");
        devFees[msg.sender].amount = 0;

        erc20Token.transfer(msg.sender, amount);

        emit WithdrawFees(msg.sender, amount);
    }

    /// @dev emergency withdraw contract balance to the contract owner
    function emergencyWithdraw() external onlyOwner {
        uint256 amount = address(this).balance;
        require(amount > 0, "Error: no fees :(");
        for (uint8 i = 0; i < devList.length; i++) {
            address devAddress = devList[i];
            devFees[devAddress].amount = 0;
        }
        erc20Token.transfer(msg.sender, amount);
        emit WithdrawFees(msg.sender, amount);
    }

    /// @dev withdraw ERC20 tokens
    function withdrawTokens(address _tokenContract) external onlyOwner {
        IERC20 tokenContract = IERC20(_tokenContract);
        uint256 _amount = tokenContract.balanceOf(address(this));
        tokenContract.transfer(owner(), _amount);
        emit WithdrawWrongTokens(msg.sender, _tokenContract, _amount);
    }

    /// @dev withdraw ERC721 tokens to the contract owner
    function withdrawNFT(address _tokenContract, uint256[] memory _id)
        external
        onlyOwner
    {
        IERC721 tokenContract = IERC721(_tokenContract);
        for (uint256 i = 0; i < _id.length; i++) {
            tokenContract.safeTransferFrom(address(this), owner(), _id[i]);
            emit WithdrawWrongNfts(msg.sender, _tokenContract, _id[i]);
        }
    }
}
