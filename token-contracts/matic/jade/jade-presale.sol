// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract Presale is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable saleToken;
    uint256 public rate;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public softCap;
    uint256 public hardCap;
    uint256 public minContribution;
    uint256 public maxContribution;
    uint256 public totalRaisedWeiEquivalent;
    bool public finalized;
    bool public whitelistOnly;

    mapping(address => bool) public isWhitelisted;
    mapping(address => uint256) public contributionsNativeWei;
    mapping(address => mapping(address => uint256)) public contributionsTokenAmount;
    mapping(address => uint256) public totalContributedPerERC20;
    mapping(address => uint256) public purchased;
    mapping(address => bool) public claimed;

    struct PayToken {
        IERC20 token;
        uint8 decimals;
        uint256 priceInWeiPerWholeToken;
        bool enabled;
    }

    mapping(address => PayToken) public payTokens;
    address[] public acceptedTokensList;

    event BoughtNative(address indexed buyer, uint256 valueWei, uint256 tokenAmount);
    event BoughtERC20(address indexed buyer, address indexed payToken, uint256 payAmount, uint256 tokenAmount, uint256 weiEquivalent);
    event Claimed(address indexed buyer, uint256 tokenAmount);
    event RefundedNative(address indexed buyer, uint256 valueWei);
    event RefundedERC20(address indexed buyer, address indexed payToken, uint256 amount);
    event Finalized(bool success, uint256 totalRaisedWeiEquivalent);
    event PayTokenUpdated(address token, uint256 priceInWeiPerWholeToken, uint8 decimals, bool enabled);

    constructor(
        address _saleToken,
        uint256 _rate,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _softCapWeiEq,
        uint256 _hardCapWeiEq,
        uint256 _minContributionWei,
        uint256 _maxContributionWei
    ) Ownable(msg.sender) {
        require(_saleToken != address(0));
        require(_rate > 0);
        require(_startTime < _endTime);
        require(_softCapWeiEq <= _hardCapWeiEq);

        saleToken = IERC20(_saleToken);
        rate = _rate;
        startTime = _startTime;
        endTime = _endTime;
        softCap = _softCapWeiEq;
        hardCap = _hardCapWeiEq;
        minContribution = _minContributionWei;
        maxContribution = _maxContributionWei;
    }

    modifier whenSaleActive() {
        require(block.timestamp >= startTime && block.timestamp <= endTime);
        require(!finalized);
        _;
    }

    function setRate(uint256 _rate) external onlyOwner {
        require(_rate > 0);
        rate = _rate;
    }

    function setTimes(uint256 _start, uint256 _end) external onlyOwner {
        require(_start < _end);
        startTime = _start;
        endTime = _end;
    }

    function setCaps(uint256 _soft, uint256 _hard) external onlyOwner {
        require(_soft <= _hard);
        softCap = _soft;
        hardCap = _hard;
    }

    function setContribLimits(uint256 _min, uint256 _max) external onlyOwner {
        minContribution = _min;
        maxContribution = _max;
    }

    function setWhitelistOnly(bool on) external onlyOwner {
        whitelistOnly = on;
    }

    function addToWhitelist(address[] calldata addrs) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            isWhitelisted[addrs[i]] = true;
        }
    }

    function removeFromWhitelist(address[] calldata addrs) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            isWhitelisted[addrs[i]] = false;
        }
    }

    function addOrUpdatePayToken(address tokenAddr, uint256 priceInWeiPerWholeToken, bool enabled) external onlyOwner {
        require(tokenAddr != address(0));
        IERC20 t = IERC20(tokenAddr);
        uint8 decimals = IERC20Metadata(tokenAddr).decimals();

        PayToken storage p = payTokens[tokenAddr];
        if (!p.enabled && address(p.token) == address(0)) {
            acceptedTokensList.push(tokenAddr);
        }

        p.token = t;
        p.decimals = decimals;
        p.priceInWeiPerWholeToken = priceInWeiPerWholeToken;
        p.enabled = enabled;

        emit PayTokenUpdated(tokenAddr, priceInWeiPerWholeToken, decimals, enabled);
    }

    function getAcceptedTokens() external view returns (address[] memory) {
        return acceptedTokensList;
    }

    function buy() external payable nonReentrant whenSaleActive {
        if (whitelistOnly) {
            require(isWhitelisted[msg.sender]);
        }
        uint256 value = msg.value;
        require(value >= minContribution);
        uint256 newContributionWei = contributionsNativeWei[msg.sender] + value;
        require(newContributionWei <= maxContribution);

        uint256 newTotalWeiEq = totalRaisedWeiEquivalent + value;
        require(newTotalWeiEq <= hardCap);

        uint256 tokenAmount = (value * rate) / 1e18;

        contributionsNativeWei[msg.sender] = newContributionWei;
        purchased[msg.sender] += tokenAmount;
        totalRaisedWeiEquivalent = newTotalWeiEq;

        emit BoughtNative(msg.sender, value, tokenAmount);
    }

    function buyWithToken(address payTokenAddr, uint256 amount) external nonReentrant whenSaleActive {
        if (whitelistOnly) {
            require(isWhitelisted[msg.sender]);
        }
        PayToken storage p = payTokens[payTokenAddr];
        require(p.enabled);
        require(amount > 0);

        p.token.safeTransferFrom(msg.sender, address(this), amount);

        uint256 weiEq = (amount * p.priceInWeiPerWholeToken) / (10 ** p.decimals);
        require(weiEq >= minContribution);

        uint256 userTotalAfter = contributionsNativeWei[msg.sender] + _sumUserERC20WeiEq(msg.sender) + weiEq;
        require(userTotalAfter <= maxContribution);

        uint256 newTotalAfter = totalRaisedWeiEquivalent + weiEq;
        require(newTotalAfter <= hardCap);

        uint256 tokenAmount = (weiEq * rate) / 1e18;

        contributionsTokenAmount[msg.sender][payTokenAddr] += amount;
        totalContributedPerERC20[payTokenAddr] += amount;
        purchased[msg.sender] += tokenAmount;
        totalRaisedWeiEquivalent = newTotalAfter;

        emit BoughtERC20(msg.sender, payTokenAddr, amount, tokenAmount, weiEq);
    }

    function _sumUserERC20WeiEq(address user) internal view returns (uint256 sumWeiEq) {
        sumWeiEq = 0;
        for (uint256 i = 0; i < acceptedTokensList.length; i++) {
            address taddr = acceptedTokensList[i];
            PayToken storage p = payTokens[taddr];
            if (!p.enabled) continue;
            uint256 amt = contributionsTokenAmount[user][taddr];
            if (amt == 0) continue;
            uint256 weiEq = (amt * p.priceInWeiPerWholeToken) / (10 ** p.decimals);
            sumWeiEq += weiEq;
        }
    }

    function claimRefundNative() external nonReentrant {
        require(block.timestamp > endTime);
        require(totalRaisedWeiEquivalent < softCap);
        uint256 contributed = contributionsNativeWei[msg.sender];
        require(contributed > 0);

        contributionsNativeWei[msg.sender] = 0;
        purchased[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: contributed}("");
        require(success);

        emit RefundedNative(msg.sender, contributed);
    }

    function claimRefundERC20(address payTokenAddr) external nonReentrant {
        require(block.timestamp > endTime);
        require(totalRaisedWeiEquivalent < softCap);
        uint256 amt = contributionsTokenAmount[msg.sender][payTokenAddr];
        require(amt > 0);

        contributionsTokenAmount[msg.sender][payTokenAddr] = 0;
        purchased[msg.sender] = 0;

        PayToken storage p = payTokens[payTokenAddr];
        require(address(p.token) != address(0));

        p.token.safeTransfer(msg.sender, amt);
        emit RefundedERC20(msg.sender, payTokenAddr, amt);
    }

    function claimTokens() external nonReentrant {
        require(finalized);
        require(totalRaisedWeiEquivalent >= softCap);
        require(!claimed[msg.sender]);
        uint256 amount = purchased[msg.sender];
        require(amount > 0);

        claimed[msg.sender] = true;
        saleToken.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function finalize() external onlyOwner {
        require(block.timestamp > endTime);
        require(!finalized);
        finalized = true;
        emit Finalized(totalRaisedWeiEquivalent >= softCap, totalRaisedWeiEquivalent);
    }

    function withdrawRaisedNative(address payable to) external onlyOwner nonReentrant {
        require(finalized);
        require(totalRaisedWeiEquivalent >= softCap);
        uint256 balance = address(this).balance;
        require(balance > 0);
        (bool success, ) = to.call{value: balance}("");
        require(success);
    }

    function withdrawRaisedERC20(address payTokenAddr, address to) external onlyOwner {
        require(finalized);
        require(totalRaisedWeiEquivalent >= softCap);
        PayToken storage p = payTokens[payTokenAddr];
        require(address(p.token) != address(0));
        uint256 bal = p.token.balanceOf(address(this));
        require(bal > 0);
        p.token.safeTransfer(to, bal);
    }

    function withdrawUnsoldSaleTokens(address to) external onlyOwner {
        require(finalized);
        uint256 contractTokenBal = saleToken.balanceOf(address(this));
        require(contractTokenBal > 0);
        saleToken.safeTransfer(to, contractTokenBal);
    }

    function rescueERC20(address erc20, address to) external onlyOwner {
        require(erc20 != address(saleToken));
        IERC20(erc20).safeTransfer(to, IERC20(erc20).balanceOf(address(this)));
    }

    receive() external payable {
        revert();
    }

    fallback() external payable {
        revert();
    }
}
