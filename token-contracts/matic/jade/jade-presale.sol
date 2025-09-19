// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract Presale is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable saleToken; 
    uint256 public rate; // tokens per 1 MATIC (wei)

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
    ) {
        require(_saleToken != address(0), "sale token zero");
        require(_rate > 0, "rate 0");
        require(_startTime < _endTime, "bad times");
        require(_softCapWeiEq <= _hardCapWeiEq, "soft>hard");

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
        require(block.timestamp >= startTime && block.timestamp <= endTime, "sale inactive");
        require(!finalized, "finalized");
        _;
    }

    function setRate(uint256 _rate) external onlyOwner {
        require(_rate > 0, "rate 0");
        rate = _rate;
    }

    function setTimes(uint256 _start, uint256 _end) external onlyOwner {
        require(_start < _end, "bad times");
        startTime = _start;
        endTime = _end;
    }

    function setCaps(uint256 _soft, uint256 _hard) external onlyOwner {
        require(_soft <= _hard, "soft>hard");
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
        require(tokenAddr != address(0), "zero token");
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
            require(isWhitelisted[msg.sender], "not whitelisted");
        }
        uint256 value = msg.value;
        require(value >= minContribution, "below min");
        uint256 newContributionWei = contributionsNativeWei[msg.sender] + value;
        require(newContributionWei <= maxContribution, "over max per address");

        uint256 newTotalWeiEq = totalRaisedWeiEquivalent + value;
        require(newTotalWeiEq <= hardCap, "hard cap reached");

        uint256 tokenAmount = (value * rate) / 1e18;

        contributionsNativeWei[msg.sender] = newContributionWei;
        purchased[msg.sender] += tokenAmount;
        totalRaisedWeiEquivalent = newTotalWeiEq;

        emit BoughtNative(msg.sender, value, tokenAmount);
    }

    function buyWithToken(address payTokenAddr, uint256 amount) external nonReentrant whenSaleActive {
        if (whitelistOnly) {
            require(isWhitelisted[msg.sender], "not whitelisted");
        }
        PayToken storage p = payTokens[payTokenAddr];
        require(p.enabled, "payment token not accepted");
        require(amount > 0, "zero amount");

        p.token.safeTransferFrom(msg.sender, address(this), amount);

        uint256 weiEq = (amount * p.priceInWeiPerWholeToken) / (10 ** p.decimals);
        require(weiEq >= minContribution, "below min equivalent");

        uint256 userTotalAfter = contributionsNativeWei[msg.sender] + _sumUserERC20WeiEq(msg.sender) + weiEq;
        require(userTotalAfter <= maxContribution, "over max per address");

        uint256 newTotalAfter = totalRaisedWeiEquivalent + weiEq;
        require(newTotalAfter <= hardCap, "hard cap reached");

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
        require(block.timestamp > endTime, "sale not ended");
        require(totalRaisedWeiEquivalent < softCap, "soft cap reached");
        uint256 contributed = contributionsNativeWei[msg.sender];
        require(contributed > 0, "no contribution");

        contributionsNativeWei[msg.sender] = 0;
        purchased[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: contributed}("");
        require(success, "refund failed");

        emit RefundedNative(msg.sender, contributed);
    }

    function claimRefundERC20(address payTokenAddr) external nonReentrant {
        require(block.timestamp > endTime, "sale not ended");
        require(totalRaisedWeiEquivalent < softCap, "soft cap reached");
        uint256 amt = contributionsTokenAmount[msg.sender][payTokenAddr];
        require(amt > 0, "no contribution for token");

        contributionsTokenAmount[msg.sender][payTokenAddr] = 0;
        purchased[msg.sender] = 0;

        PayToken storage p = payTokens[payTokenAddr];
        require(address(p.token) != address(0), "unknown token");

        p.token.safeTransfer(msg.sender, amt);
        emit RefundedERC20(msg.sender, payTokenAddr, amt);
    }

    function claimTokens() external nonReentrant {
        require(finalized, "not finalized");
        require(totalRaisedWeiEquivalent >= softCap, "sale failed");
        require(!claimed[msg.sender], "already claimed");
        uint256 amount = purchased[msg.sender];
        require(amount > 0, "no tokens to claim");

        claimed[msg.sender] = true;
        saleToken.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function finalize() external onlyOwner {
        require(block.timestamp > endTime, "sale not ended");
        require(!finalized, "already finalized");
        finalized = true;
        emit Finalized(totalRaisedWeiEquivalent >= softCap, totalRaisedWeiEquivalent);
    }

    function withdrawRaisedNative(address payable to) external onlyOwner nonReentrant {
        require(finalized, "not finalized");
        require(totalRaisedWeiEquivalent >= softCap, "soft cap not reached");
        uint256 balance = address(this).balance;
        require(balance > 0, "no funds");
        (bool success, ) = to.call{value: balance}("");
        require(success, "withdraw failed");
    }

    function withdrawRaisedERC20(address payTokenAddr, address to) external onlyOwner {
        require(finalized, "not finalized");
        require(totalRaisedWeiEquivalent >= softCap, "soft cap not reached");
        PayToken storage p = payTokens[payTokenAddr];
        require(address(p.token) != address(0), "unknown token");
        uint256 bal = p.token.balanceOf(address(this));
        require(bal > 0, "no token funds");
        p.token.safeTransfer(to, bal);
    }

    function withdrawUnsoldSaleTokens(address to) external onlyOwner {
        require(finalized, "not finalized");
        uint256 contractTokenBal = saleToken.balanceOf(address(this));
        require(contractTokenBal > 0, "no tokens");
        saleToken.safeTransfer(to, contractTokenBal);
    }

    function rescueERC20(address erc20, address to) external onlyOwner {
        require(erc20 != address(saleToken), "cannot rescue sale token");
        IERC20(erc20).safeTransfer(to, IERC20(erc20).balanceOf(address(this)));
    }

    receive() external payable {
        revert("use buy()");
    }

    fallback() external payable {
        revert("use buy()");
    }
}
