// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "./interfaces/IERC20.sol";
import { IUniswapV2Router02, IUniswapV2Factory, IUniswapV2Pair } from "./interfaces/IUniswapV2.sol";

/**
 * @title WallosTokenV2
 * @notice Versão otimizada com swap automático de taxas
 * @dev Diferenças da V1:
 *      - Acumula taxas no contrato
 *      - Swap automático acontece em COMPRAS/TRANSFERS (não em vendas)
 *      - Evita conflitos com o par durante vendas
 *      - Gas estimado corretamente pelos wallets
 */
contract WallosTokenV2 is IERC20 {
    // ============ Errors ============
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientAllowance();
    error NotOwner();
    error TradingNotEnabled();
    error MaxWalletExceeded();
    error MaxTransactionExceeded();
    error TaxTooHigh();
    error InvalidPair();
    error Blacklisted();

    // ============ Events ============
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TaxesUpdated(uint256 buyTax, uint256 sellTax, uint256 transferTax);
    event TaxReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event LiquidityPairAdded(address indexed pair, address indexed liquidityToken);
    event LiquidityPairRemoved(address indexed pair);
    event ExcludedFromTax(address indexed account, bool excluded);
    event ExcludedFromLimits(address indexed account, bool excluded);
    event BlacklistUpdated(address indexed account, bool blacklisted);
    event MaxWalletUpdated(uint256 oldMax, uint256 newMax);
    event MaxTransactionUpdated(uint256 oldMax, uint256 newMax);
    event TradingEnabled(uint256 timestamp);
    event TaxSwapped(uint256 tokensSwapped, uint256 usdtReceived);
    event SwapThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    // ============ Token Metadata ============
    string public constant name = "Wallos";
    string public constant symbol = "WLS";
    uint8 public constant decimals = 18;

    // ============ Supply ============
    uint256 private constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 private _totalSupply;

    // ============ Balances & Allowances ============
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ============ Ownership ============
    address public owner;

    // ============ Tax Configuration ============
    uint256 public buyTax;
    uint256 public sellTax;
    uint256 public transferTax;
    uint256 public constant MAX_TAX = 2500; // 25%
    uint256 public constant TAX_DENOMINATOR = 10000;

    address public taxReceiver;

    // ============ DEX Integration ============
    IUniswapV2Router02 public immutable router;
    address public immutable USDT;
    address public liquidityPair;

    // ============ Auto Swap ============
    uint256 public swapThreshold; // Quantidade mínima para triggerar swap
    bool private _inSwap;
    bool public swapEnabled = true;

    // ============ Exclusions ============
    mapping(address => bool) public isExcludedFromTax;
    mapping(address => bool) public isExcludedFromLimits;
    mapping(address => bool) public isBlacklisted;

    // ============ Limits ============
    uint256 public maxWallet;
    uint256 public maxTransaction;
    bool public limitsEnabled = true;

    // ============ Trading Control ============
    bool public tradingEnabled;
    uint256 public tradingEnabledAt;

    // ============ Modifiers ============
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier lockSwap() {
        _inSwap = true;
        _;
        _inSwap = false;
    }

    // ============ Constructor ============
    constructor(address _router, address _usdt, address _taxReceiver) {
        if (_router == address(0)) revert ZeroAddress();
        if (_usdt == address(0)) revert ZeroAddress();
        if (_taxReceiver == address(0)) revert ZeroAddress();

        owner = msg.sender;
        router = IUniswapV2Router02(_router);
        USDT = _usdt;
        taxReceiver = _taxReceiver;

        // Initialize supply
        _totalSupply = TOTAL_SUPPLY;
        _balances[msg.sender] = TOTAL_SUPPLY;

        // Set initial limits (2% of supply)
        maxWallet = TOTAL_SUPPLY * 200 / TAX_DENOMINATOR;
        maxTransaction = TOTAL_SUPPLY * 200 / TAX_DENOMINATOR;

        // Swap threshold: 0.01% of supply (100k tokens)
        swapThreshold = TOTAL_SUPPLY / 10000;

        // Exclude owner and contract from tax and limits
        isExcludedFromTax[msg.sender] = true;
        isExcludedFromTax[address(this)] = true;
        isExcludedFromLimits[msg.sender] = true;
        isExcludedFromLimits[address(this)] = true;

        // Approve router for swaps
        _allowances[address(this)][_router] = type(uint256).max;

        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ============ ERC20 Functions ============

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address _owner, address spender) external view override returns (uint256) {
        return _allowances[_owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) revert InsufficientAllowance();
            unchecked {
                _allowances[from][msg.sender] = currentAllowance - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _approve(address _owner, address spender, uint256 amount) internal {
        if (_owner == address(0)) revert ZeroAddress();
        if (spender == address(0)) revert ZeroAddress();
        _allowances[_owner][spender] = amount;
        emit Approval(_owner, spender, amount);
    }

    // ============ Transfer Logic ============

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Check blacklist
        if (isBlacklisted[from] || isBlacklisted[to]) revert Blacklisted();

        // Check trading enabled
        if (!tradingEnabled && from != owner && to != owner) {
            revert TradingNotEnabled();
        }

        // Check balance
        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance();

        // Determine transaction type
        bool isBuy = from == liquidityPair;
        bool isSell = to == liquidityPair;

        // Check limits
        if (limitsEnabled && !isExcludedFromLimits[from] && !isExcludedFromLimits[to]) {
            if (amount > maxTransaction) revert MaxTransactionExceeded();
            if (!isSell && _balances[to] + amount > maxWallet) {
                revert MaxWalletExceeded();
            }
        }

        // Auto swap: acontece ANTES da transferência, em compras ou transfers (não vendas)
        // Isso evita conflito com o par durante vendas
        if (
            swapEnabled &&
            !_inSwap &&
            !isSell && // Não fazer swap durante vendas!
            _balances[address(this)] >= swapThreshold &&
            liquidityPair != address(0)
        ) {
            _swapTaxToUSDT();
        }

        // Calculate tax
        uint256 taxAmount = 0;
        if (!isExcludedFromTax[from] && !isExcludedFromTax[to]) {
            if (isBuy && buyTax > 0) {
                taxAmount = (amount * buyTax) / TAX_DENOMINATOR;
            } else if (isSell && sellTax > 0) {
                taxAmount = (amount * sellTax) / TAX_DENOMINATOR;
            } else if (!isBuy && !isSell && transferTax > 0) {
                taxAmount = (amount * transferTax) / TAX_DENOMINATOR;
            }
        }

        // Execute transfer
        unchecked {
            _balances[from] = fromBalance - amount;
        }

        if (taxAmount > 0) {
            uint256 receiveAmount = amount - taxAmount;
            unchecked {
                _balances[to] += receiveAmount;
                _balances[address(this)] += taxAmount; // Taxa fica no contrato
            }
            emit Transfer(from, to, receiveAmount);
            emit Transfer(from, address(this), taxAmount);
        } else {
            unchecked {
                _balances[to] += amount;
            }
            emit Transfer(from, to, amount);
        }
    }

    // ============ Auto Swap ============

    /**
     * @notice Swap acumulado de taxas para USDT
     * @dev Chamado automaticamente durante compras/transfers quando threshold é atingido
     */
    function _swapTaxToUSDT() internal lockSwap {
        uint256 contractBalance = _balances[address(this)];
        if (contractBalance == 0) return;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = USDT;

        uint256 balanceBefore = IERC20(USDT).balanceOf(taxReceiver);

        try router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            contractBalance,
            0,
            path,
            taxReceiver,
            block.timestamp
        ) {
            uint256 received = IERC20(USDT).balanceOf(taxReceiver) - balanceBefore;
            emit TaxSwapped(contractBalance, received);
        } catch {
            // Se falhar, tokens ficam no contrato para próxima tentativa
        }
    }

    /**
     * @notice Swap manual de taxas (caso automático falhe)
     */
    function manualSwap() external onlyOwner {
        if (_balances[address(this)] > 0) {
            _swapTaxToUSDT();
        }
    }

    /**
     * @notice Resgatar taxas como tokens (emergência)
     */
    function rescueTaxTokens(address to) external onlyOwner {
        uint256 contractBalance = _balances[address(this)];
        if (contractBalance > 0) {
            unchecked {
                _balances[address(this)] = 0;
                _balances[to] += contractBalance;
            }
            emit Transfer(address(this), to, contractBalance);
        }
    }

    // ============ Liquidity Pair ============

    /**
     * @notice Criar par de liquidez com USDT
     */
    function createLiquidityPair() external onlyOwner returns (address pair) {
        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());

        pair = factory.getPair(address(this), USDT);
        if (pair == address(0)) {
            pair = factory.createPair(address(this), USDT);
        }

        liquidityPair = pair;
        isExcludedFromLimits[pair] = true;

        emit LiquidityPairAdded(pair, USDT);
        return pair;
    }

    /**
     * @notice Definir par manualmente (se já existir)
     */
    function setLiquidityPair(address pair) external onlyOwner {
        if (pair == address(0)) revert ZeroAddress();
        liquidityPair = pair;
        isExcludedFromLimits[pair] = true;
        emit LiquidityPairAdded(pair, USDT);
    }

    // ============ Tax Configuration ============

    function setTaxes(uint256 _buyTax, uint256 _sellTax, uint256 _transferTax) external onlyOwner {
        if (_buyTax > MAX_TAX || _sellTax > MAX_TAX || _transferTax > MAX_TAX) {
            revert TaxTooHigh();
        }
        buyTax = _buyTax;
        sellTax = _sellTax;
        transferTax = _transferTax;
        emit TaxesUpdated(_buyTax, _sellTax, _transferTax);
    }

    function setTaxReceiver(address _taxReceiver) external onlyOwner {
        if (_taxReceiver == address(0)) revert ZeroAddress();
        address oldReceiver = taxReceiver;
        taxReceiver = _taxReceiver;
        emit TaxReceiverUpdated(oldReceiver, _taxReceiver);
    }

    function setSwapThreshold(uint256 _threshold) external onlyOwner {
        uint256 oldThreshold = swapThreshold;
        swapThreshold = _threshold;
        emit SwapThresholdUpdated(oldThreshold, _threshold);
    }

    function setSwapEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
    }

    // ============ Exclusion Management ============

    function setExcludedFromTax(address account, bool excluded) external onlyOwner {
        isExcludedFromTax[account] = excluded;
        emit ExcludedFromTax(account, excluded);
    }

    function setExcludedFromLimits(address account, bool excluded) external onlyOwner {
        isExcludedFromLimits[account] = excluded;
        emit ExcludedFromLimits(account, excluded);
    }

    function batchSetExcludedFromTax(address[] calldata accounts, bool excluded) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            isExcludedFromTax[accounts[i]] = excluded;
            emit ExcludedFromTax(accounts[i], excluded);
        }
    }

    // ============ Blacklist ============

    function setBlacklisted(address account, bool blacklisted) external onlyOwner {
        if (account == owner || account == address(this) || account == address(router)) {
            revert ZeroAddress();
        }
        isBlacklisted[account] = blacklisted;
        emit BlacklistUpdated(account, blacklisted);
    }

    // ============ Limits ============

    function setMaxWallet(uint256 _maxWallet) external onlyOwner {
        if (_maxWallet < TOTAL_SUPPLY / 200) revert ZeroAmount();
        uint256 oldMax = maxWallet;
        maxWallet = _maxWallet;
        emit MaxWalletUpdated(oldMax, _maxWallet);
    }

    function setMaxTransaction(uint256 _maxTransaction) external onlyOwner {
        if (_maxTransaction < TOTAL_SUPPLY / 1000) revert ZeroAmount();
        uint256 oldMax = maxTransaction;
        maxTransaction = _maxTransaction;
        emit MaxTransactionUpdated(oldMax, _maxTransaction);
    }

    function removeLimits() external onlyOwner {
        limitsEnabled = false;
        maxWallet = TOTAL_SUPPLY;
        maxTransaction = TOTAL_SUPPLY;
    }

    // ============ Trading ============

    function enableTrading() external onlyOwner {
        if (tradingEnabled) return;
        tradingEnabled = true;
        tradingEnabledAt = block.timestamp;
        emit TradingEnabled(block.timestamp);
    }

    // ============ Ownership ============

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();

        address oldOwner = owner;
        owner = newOwner;

        isExcludedFromTax[oldOwner] = false;
        isExcludedFromLimits[oldOwner] = false;
        isExcludedFromTax[newOwner] = true;
        isExcludedFromLimits[newOwner] = true;

        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function renounceOwnership() external onlyOwner {
        address oldOwner = owner;
        owner = address(0);
        isExcludedFromTax[oldOwner] = false;
        isExcludedFromLimits[oldOwner] = false;
        emit OwnershipTransferred(oldOwner, address(0));
    }

    // ============ Emergency ============

    function recoverTokens(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(this)) revert InvalidPair();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).transfer(to, amount);
    }

    function recoverNative(address payable to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        to.transfer(address(this).balance);
    }

    // ============ View Functions ============

    function getContractTokenBalance() external view returns (uint256) {
        return _balances[address(this)];
    }

    function getTaxConfig() external view returns (
        uint256 _buyTax,
        uint256 _sellTax,
        uint256 _transferTax,
        address _taxReceiver
    ) {
        return (buyTax, sellTax, transferTax, taxReceiver);
    }

    function getLimitsConfig() external view returns (
        uint256 _maxWallet,
        uint256 _maxTransaction,
        bool _limitsEnabled
    ) {
        return (maxWallet, maxTransaction, limitsEnabled);
    }

    function getExclusions(address account) external view returns (bool fromTax, bool fromLimits) {
        return (isExcludedFromTax[account], isExcludedFromLimits[account]);
    }

    receive() external payable {}
}
