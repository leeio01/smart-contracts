// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ZEROKOIN is ERC20, Ownable, ReentrancyGuard {
    uint8 private constant _DECIMALS = 18;
    uint256 public constant INITIAL_SUPPLY = 2_500_000_000 * (10 ** _DECIMALS);

    bool public tradingEnabled = false;
    bool public modificationsAllowed = true;
    address public dexPair;

    uint256 public tradeDelaySeconds = 60;
    mapping(address => uint256) public lastTradeTime;

    uint256 public maxGasPrice = 0;

    uint8 public taxPercent = 0;
    uint8 public constant TAX_PERCENT_MAX = 10;

    uint8 public maxWalletPercent = 100;
    uint8 public constant MAX_WALLET_PERCENT_CAP = 100;

    uint8 public maxTxPercent = 0;

    event TradingEnabled(bool enabled);
    event ModificationsDisabled();
    event TaxPercentUpdated(uint8 newTax);
    event MaxWalletPercentUpdated(uint8 newMax);
    event MaxTxPercentUpdated(uint8 newMaxTx);
    event TradeDelaySecondsUpdated(uint256 newDelay);
    event MaxGasPriceUpdated(uint256 newMaxGas);
    event DexPairUpdated(address pair);
    event WithdrawnBNB(address indexed to, uint256 amount);
    event RescuedERC20(address indexed token, address indexed to, uint256 amount);
    event CollectedFeesSwept(address indexed to, uint256 amount);

    modifier onlyWhenModifiable() {
        require(modificationsAllowed, "Modifications permanently disabled");
        _;
    }

    constructor() ERC20("Zero Koin", "ZRK") Ownable(msg.sender) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    function setTradingEnabled(bool _enabled) external onlyOwner onlyWhenModifiable {
        tradingEnabled = _enabled;
        emit TradingEnabled(_enabled);
    }

    function setDexPair(address _pair) external onlyOwner onlyWhenModifiable {
        dexPair = _pair;
        emit DexPairUpdated(_pair);
    }

    function setTaxPercent(uint8 _tax) external onlyOwner onlyWhenModifiable {
        require(_tax <= TAX_PERCENT_MAX, "Tax percent too high");
        taxPercent = _tax;
        emit TaxPercentUpdated(_tax);
    }

    function setMaxWalletPercent(uint8 _pct) external onlyOwner onlyWhenModifiable {
        require(_pct >= 1 && _pct <= MAX_WALLET_PERCENT_CAP, "Invalid percent");
        maxWalletPercent = _pct;
        emit MaxWalletPercentUpdated(_pct);
    }

    function setMaxTxPercent(uint8 _pct) external onlyOwner onlyWhenModifiable {
        require(_pct <= 100, "Invalid percent");
        maxTxPercent = _pct;
        emit MaxTxPercentUpdated(_pct);
    }

    function setTradeDelaySeconds(uint256 _seconds) external onlyOwner onlyWhenModifiable {
        require(_seconds <= 3600, "Delay too long");
        tradeDelaySeconds = _seconds;
        emit TradeDelaySecondsUpdated(_seconds);
    }

    function setMaxGasPrice(uint256 _maxGasWei) external onlyOwner onlyWhenModifiable {
        maxGasPrice = _maxGasWei;
        emit MaxGasPriceUpdated(_maxGasWei);
    }

    function disableModificationsPermanently() external onlyOwner onlyWhenModifiable {
        modificationsAllowed = false;
        emit ModificationsDisabled();
    }

    function withdrawBNB(address payable _to) external onlyOwner nonReentrant {
        uint256 bal = address(this).balance;
        require(bal > 0, "No BNB to withdraw");
        (bool success, ) = _to.call{value: bal}("");
        require(success, "BNB transfer failed");
        emit WithdrawnBNB(_to, bal);
    }

    function rescueERC20(address tokenAddress, address to) external onlyOwner nonReentrant {
        require(tokenAddress != address(this), "Use sweepCollectedFees for this token");
        IERC20 token = IERC20(tokenAddress);
        uint256 bal = token.balanceOf(address(this));
        require(bal > 0, "No token balance to rescue");
        token.transfer(to, bal);
        emit RescuedERC20(tokenAddress, to, bal);
    }

    function sweepCollectedFees(address to, uint256 amount) external onlyOwner nonReentrant {
        uint256 bal = balanceOf(address(this));
        require(amount > 0 && amount <= bal, "Invalid sweep amount");
        _transferWithChecks(address(this), to, amount);
        emit CollectedFeesSwept(to, amount);
    }

    receive() external payable {}

    function _transferWithChecks(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0) && recipient != address(0), "Zero address");
        require(amount > 0, "Amount must be > 0");

        if (maxGasPrice > 0) {
            require(tx.gasprice <= maxGasPrice, "Gas price above allowed limit");
        }

        bool isBuy = (sender == dexPair) && (dexPair != address(0));
        bool isSell = (recipient == dexPair) && (dexPair != address(0));
        bool isTradeWithPair = isBuy || isSell;

        if (isTradeWithPair && !tradingEnabled) {
            require(sender == owner() || recipient == owner(), "Trading not enabled");
        }

        if (isTradeWithPair) {
            address user = isBuy ? recipient : sender;
            require(block.timestamp >= lastTradeTime[user] + tradeDelaySeconds, "Trade cooldown active");
            lastTradeTime[user] = block.timestamp;
        }

        if (maxTxPercent > 0) {
            uint256 maxTxAmount = (totalSupply() * maxTxPercent) / 100;
            require(amount <= maxTxAmount, "Transfer exceeds max transaction amount");
        }

        uint256 transferAmount = amount;

        if (taxPercent > 0 && isTradeWithPair && sender != owner() && recipient != owner()) {
            uint256 fee = (amount * taxPercent) / 100;
            if (fee > 0) {
                super._transfer(sender, address(this), fee);
                transferAmount = amount - fee;
            }
        }

        if (maxWalletPercent > 0 && recipient != dexPair) {
            uint256 maxWalletAmount = (totalSupply() * maxWalletPercent) / 100;
            require(balanceOf(recipient) + transferAmount <= maxWalletAmount, "Recipient would exceed max wallet limit");
        }

        super._transfer(sender, recipient, transferAmount);
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transferWithChecks(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _spendAllowance(sender, _msgSender(), amount);
        _transferWithChecks(sender, recipient, amount);
        return true;
    }
}
