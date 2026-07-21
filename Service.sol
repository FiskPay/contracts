//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

interface IProxy{

    // Returns the protocol owner used for admin actions and fee collection.
    function Owner() external view returns(address);
}

interface IERC20{

    // Current token ticker used only for UI/service lookup.
    function symbol() external view returns(string memory);

    // Token decimals cached when the token is added.
    function decimals() external view returns(uint8);

    // Current token balance for an account.
    function balanceOf(address owner) external view returns(uint256);

    // Moves tokens from this contract to a recipient.
    function transfer(address to, uint256 amount) external returns(bool);

    // Pulls approved tokens into this contract.
    function transferFrom(address from, address to, uint256 amount) external returns(bool);
}

contract Service{

//-----------------------------------------------------------------------// v EVENTS

    event Registered(address indexed client, address indexed signer);
    event Deposit(address indexed from, address indexed to, string symbol, uint32 amount, uint8 server, string character);
    event Withdrawal(address indexed from, address indexed to, string symbol, uint32 amount, uint8 server, string character, uint32 refund);
    event TokenAdded(address indexed token, string symbol);
    event TokenSymbolUpdated(address indexed token, string oldSymbol, string newSymbol);
    event TokenFeeSet(address indexed token, uint8 fee);
    event TokenTopupEnabledSet(address indexed token, bool enabled);
    event PolFeeSet(uint256 amount);
    event SignerFundAmountSet(uint256 amount);
    event SignerMinBalanceSet(uint256 amount);
    event ReimbursePerWithdrawSet(uint256 amount);
    event PolWithdrawn(address indexed to, uint256 amount);
    event PolFeeRedirected(address indexed to, uint256 amount);
    event SignerReimbursed(address indexed signer, uint256 amount);
    event DirectWithdraw(address indexed client, address indexed token, uint32 amount, uint256 claimed, uint256 fee);

//-----------------------------------------------------------------------// v INTERFACES

    IProxy constant private proxy = IProxy(proxyAddress);

//-----------------------------------------------------------------------// v BOOLEANS

    bool private locked;

//-----------------------------------------------------------------------// v ADDRESSES

    address constant private proxyAddress = 0xFCE63f00cC7b6BC7DDE11D9A4B00EDD1FD2c2dc6;

//-----------------------------------------------------------------------// v NUMBERS

    uint256 private reimbursePerWithdraw = 0.1 ether;   // Safety cap for one withdrawal gas reimbursement.
    uint256 private polFeeFlat = 0.125 ether;           // Native POL fee paid by players on topup.
    uint256 private signerFundAmount = 1 ether;         // POL sent to a new signer wallet during registration.
    uint256 private signerMinBalance = 4 ether;         // Signers above this native balance are not reimbursed.

    uint8 constant private maxTokenFeePerThousand = 250;            // Highest fee any token can be configured to charge (25%).
    uint256 constant private maxPolFeeFlat = 5 ether;               // Highest POL topup fee the owner can configure.
    uint256 constant private maxSignerFundAmount = 5 ether;         // Highest initial POL funding sent to a signer.
    uint256 constant private maxSignerMinBalance = 5 ether;         // Highest signer balance threshold for reimbursement.
    uint256 constant private maxReimbursePerWithdraw = 0.5 ether;   // Highest reimbursement cap for a single withdrawal.
    uint256 constant private maxPolBalance = 100 ether;             // Contract POL balance target before topup fees redirect to owner.


//-----------------------------------------------------------------------// v STRINGS

    string constant public Name = "Service";
    address[] private tokens;					// Token addresses are canonical; symbols can change.

//-----------------------------------------------------------------------// v STRUCTS

    struct Client{

        bytes32 key;                            // Service login key derived from client wallet and signup hash.
        address signer;                         // Hot wallet allowed to submit this client's player withdrawals.
        mapping(address => uint32) balance;     // Client balances keyed by token address.
    }

    struct Token{

        bool added;                             // Distinguishes a real token from an empty mapping slot.
        bool topupEnabled;                      // Blocks new deposits only; withdrawals remain available.
        uint8 decimals;                         // Cached once to avoid repeated token calls in hot paths.
        uint8 fee;                              // Fee per thousand, e.g. 10 means 1%.
        string symbol;                          // Display/lookup symbol; balances do not depend on this.
    }

//-----------------------------------------------------------------------// v MAPPINGS

    mapping(address => Client) private clients;         // Client wallet => client data.
    mapping(address => Token) private tokenInfo;        // Token address => token config.
    mapping(string => address) private tokenAddress;    // Current token symbol => token address.

//-----------------------------------------------------------------------// v ERRORS

    error OwnerOnly();
    error Reentrant();
    error ZeroAddress();
    error UnsupportedToken();
    error AlreadyAdded();
    error AliasUsed();
    error ClientNotRegistered();
    error InvalidAmount();
    error InvalidFee();
    error InvalidSigner();
    error Expired();
    error InsufficientBalance();
    error TransferFailed();

//-----------------------------------------------------------------------// v MODIFIERS

    modifier ownerOnly() {

        // Only the Proxy owner can change Service configuration.
        if(proxy.Owner() != msg.sender)
            revert OwnerOnly();
        _;
    }

    modifier nonReentrant() {

        // Blocks recursive calls during external POL/ERC20 transfers.
        if(locked)
            revert Reentrant();

        locked = true;
        _;
        locked = false;
    }

//-----------------------------------------------------------------------// v PRIVATE FUNCTIONS

    // Transfers ERC20 tokens and accepts both standard bool returns and old no-return tokens.
    function _safeTransfer(address _token, address _to, uint256 _amount) private{

        if(_amount == 0)
            return;

        (bool ok, bytes memory data) = _token.call(abi.encodeWithSelector(IERC20.transfer.selector, _to, _amount));

        if(!ok || (data.length != 0 && !abi.decode(data, (bool))))
            revert TransferFailed();
    }

    // Pulls ERC20 tokens and accepts both standard bool returns and old no-return tokens.
    function _safeTransferFrom(address _token, address _from, address _to, uint256 _amount) private{

        if(_amount == 0)
            revert InvalidAmount();

        (bool ok, bytes memory data) = _token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, _from, _to, _amount));

        if(!ok || (data.length != 0 && !abi.decode(data, (bool))))
            revert TransferFailed();
    }

    // Updates one token fee after checking the token exists and the fee is below the hard cap.
    function _setTokenFee(address _token, uint8 _perThousand) private{

        if(!tokenInfo[_token].added)
            revert UnsupportedToken();
        if(_perThousand > maxTokenFeePerThousand)
            revert InvalidAmount();

        tokenInfo[_token].fee = _perThousand;

        emit TokenFeeSet(_token, _perThousand);
    }

    // Shared balance withdrawal logic used by player withdrawals and direct client claims.
    function _withdrawBalance(address _token, address _client, uint32 _amount, address _to, address _feeTo) private returns(uint256 totalAmount, uint256 claimAmount, uint256 feeAmount){

        Token memory token = tokenInfo[_token];

        if(!token.added)
            revert UnsupportedToken();
        if(clients[_client].balance[_token] < _amount)
            revert InsufficientBalance();

        totalAmount = uint256(_amount) * (10 ** token.decimals);
        feeAmount = totalAmount * token.fee / 1000;
        claimAmount = totalAmount - feeAmount;

        // Effects happen before token transfers to reduce reentrancy risk.
        clients[_client].balance[_token] -= _amount;

        _safeTransfer(_token, _to, claimAmount);
        _safeTransfer(_token, _feeTo, feeAmount);
    }

    // Reimburses a registered signer for withdrawal gas when below the configured balance threshold.
    function _reimburseSigner(address _signer, uint256 _amount) private returns(uint256){

        if(_amount == 0 || _signer.balance >= signerMinBalance || reimbursePerWithdraw == 0)
            return 0;

        uint256 amount = _amount;
        uint256 available = address(this).balance;

        if(amount > reimbursePerWithdraw)
            amount = reimbursePerWithdraw;
        if(amount > available)
            amount = available;
        if(amount == 0)
            return 0;

        (bool ok, ) = payable(_signer).call{value : amount}("");

        if(!ok)
            revert TransferFailed();

        emit SignerReimbursed(_signer, amount);

        return amount;
    }

    // Keeps POL fees until the reserve cap is reached, then redirects only the overflow to the owner.
    function _redirectPolFeeIfCapped(uint256 _amount) private{

        if(_amount == 0)
            return;

        uint256 balanceBeforeFee = address(this).balance - _amount;

        if(balanceBeforeFee < maxPolBalance){

            uint256 balanceAfterFee = balanceBeforeFee + _amount;

            if(balanceAfterFee <= maxPolBalance)
                return;

            _amount = balanceAfterFee - maxPolBalance;
        }

        address owner = proxy.Owner();
        (bool ok, ) = payable(owner).call{value : _amount}("");

        if(!ok)
            revert TransferFailed();

        emit PolFeeRedirected(owner, _amount);
    }

//-----------------------------------------------------------------------// v GET FUNCTIONS

    // Returns the service login key for a client wallet.
    function GetClientKey(address _client) public view returns(bytes32){

        return clients[_client].key;
    }

    // Returns the signer wallet registered for a client wallet.
    function GetClientSignerAddress(address _client) public view returns(address){

        return clients[_client].signer;
    }

    // Returns a client balance using a symbol lookup.
    function GetClientBalance(string calldata _symbol, address _client) public view returns(uint32){

        address token = tokenAddress[_symbol];

        if(token == address(0))
            return 0;

        return clients[_client].balance[token];
    }

    // Returns a client balance by canonical token address.
    function GetClientBalanceByToken(address _token, address _client) public view returns(uint32){

        return clients[_client].balance[_token];
    }

    // Returns token symbols for frontends while keeping balances address-based.
    function GetTokens() public view returns(string[] memory){

        uint256 depth = tokens.length;
        string[] memory symbols = new string[](depth);

        for(uint256 i = 0; i < depth; i++)
            symbols[i] = tokenInfo[tokens[i]].symbol;

        return symbols;
    }

    // Resolves a current token symbol to its token contract address.
    function GetTokenAddress(string calldata _symbol) public view returns(address){

        return tokenAddress[_symbol];
    }

    // Returns cached token decimals by token address.
    function GetTokenDecimals(address _token) public view returns(uint8){

        return tokenInfo[_token].decimals;
    }

    // Returns token fee by current symbol.
    function GetTokenFee(string calldata _symbol) public view returns(uint8){

        return tokenInfo[tokenAddress[_symbol]].fee;
    }

    // Returns token fee by canonical token address.
    function GetTokenFeeByAddress(address _token) public view returns(uint8){

        return tokenInfo[_token].fee;
    }

    // Returns the hard cap for every per-token fee.
    function GetMaxTokenFeePerThousand() public pure returns(uint8){

        return maxTokenFeePerThousand;
    }

    // Returns the POL topup fee players must pay.
    function GetPolFee() public view returns(uint256){

        return polFeeFlat;
    }

    // Returns the hard cap for polFeeFlat.
    function GetMaxPolFeeFlat() public pure returns(uint256){

        return maxPolFeeFlat;
    }

    // Returns the POL reserve cap after which topup POL fees are redirected to owner.
    function GetMaxPolBalance() public pure returns(uint256){

        return maxPolBalance;
    }

    // Returns the POL amount sent to a new signer during registration.
    function GetSignerFundAmount() public view returns(uint256){

        return signerFundAmount;
    }

    // Returns the hard cap for signerFundAmount.
    function GetMaxSignerFundAmount() public pure returns(uint256){

        return maxSignerFundAmount;
    }

    // Returns the signer balance threshold below which reimbursement can happen.
    function GetSignerMinBalance() public view returns(uint256){

        return signerMinBalance;
    }

    // Returns the hard cap for signerMinBalance.
    function GetMaxSignerMinBalance() public pure returns(uint256){

        return maxSignerMinBalance;
    }

    // Returns the current signer reimbursement cap for one withdrawal.
    function GetReimbursePerWithdraw() public view returns(uint256){

        return reimbursePerWithdraw;
    }

    // Returns the hard cap for reimbursePerWithdraw.
    function GetMaxReimbursePerWithdraw() public pure returns(uint256){

        return maxReimbursePerWithdraw;
    }

    // Checks whether a client has a signer registered.
    function IsClientRegistered(address _client) public view returns(bool){

        return clients[_client].signer != address(0);
    }

    // Checks whether a token address was added by the owner.
    function IsTokenSupported(address _token) public view returns(bool){

        return tokenInfo[_token].added;
    }

    // Checks whether new topups are currently allowed for a token.
    function IsTokenTopupEnabled(address _token) public view returns(bool){

        return tokenInfo[_token].topupEnabled;
    }

    // Checks whether a client has enough balance for a player withdrawal.
    function TestWithdraw(address _from, string calldata _symbol, uint32 _amount) public view returns(bool){

        address token = tokenAddress[_symbol];

        if(token == address(0))
            return false;

        return clients[_from].balance[token] >= _amount;
    }

//-----------------------------------------------------------------------// v SET FUNCTIONS

    // Adds a token once, caching its decimals and current symbol.
    function AddToken(address _contract) public ownerOnly returns(bool){

        if(_contract == address(0))
            revert ZeroAddress();
        if(tokenInfo[_contract].added)
            revert AlreadyAdded();

        IERC20 erc20 = IERC20(_contract);
        string memory symbol = erc20.symbol();

        if(tokenAddress[symbol] != address(0))
            revert AliasUsed();

        tokenInfo[_contract] = Token(true, true, erc20.decimals(), 10, symbol);
        tokenAddress[symbol] = _contract;
        tokens.push(_contract);

        emit TokenAdded(_contract, symbol);

        return true;
    }

    // Refreshes a known token symbol from the token contract after ticker changes.
    function UpdateTokenSymbol(address _contract) public returns(bool){

        if(!tokenInfo[_contract].added)
            revert UnsupportedToken();

        string memory oldSymbol = tokenInfo[_contract].symbol;
        string memory newSymbol = IERC20(_contract).symbol();
        address current = tokenAddress[newSymbol];

        if(current != address(0) && current != _contract)
            revert AliasUsed();

        if(keccak256(abi.encodePacked(oldSymbol)) == keccak256(abi.encodePacked(newSymbol)))
            return true;

        if(tokenAddress[oldSymbol] == _contract)
            delete tokenAddress[oldSymbol];

        tokenAddress[newSymbol] = _contract;
        tokenInfo[_contract].symbol = newSymbol;

        emit TokenSymbolUpdated(_contract, oldSymbol, newSymbol);

        return true;
    }

    // Enables or disables new topups only; existing balances stay withdrawable.
    function SetTokenTopupEnabled(address _contract, bool _enabled) public ownerOnly returns(bool){

        if(!tokenInfo[_contract].added)
            revert UnsupportedToken();

        tokenInfo[_contract].topupEnabled = _enabled;

        emit TokenTopupEnabledSet(_contract, _enabled);

        return true;
    }

    // Sets the token fee in per-thousand units, e.g. 10 means 1%.
    function SetTokenFee(address _contract, uint8 _perThousand) public ownerOnly returns(bool){

        _setTokenFee(_contract, _perThousand);

        return true;
    }

    // Sets the token fee by current symbol for admin convenience.
    function SetTokenFeeBySymbol(string calldata _symbol, uint8 _perThousand) public ownerOnly returns(bool){

        address token = tokenAddress[_symbol];

        if(token == address(0))
            revert UnsupportedToken();

        _setTokenFee(token, _perThousand);

        return true;
    }

    // Sets the native POL fee required on player topups.
    function SetPolFee(uint256 _amount) public ownerOnly returns(bool){

        if(_amount > maxPolFeeFlat)
            revert InvalidAmount();

        polFeeFlat = _amount;

        emit PolFeeSet(_amount);

        return true;
    }

    // Sets how much POL a new signer receives on registration or signer change.
    function SetSignerFundAmount(uint256 _amount) public ownerOnly returns(bool){

        if(_amount > maxSignerFundAmount)
            revert InvalidAmount();

        signerFundAmount = _amount;

        emit SignerFundAmountSet(_amount);

        return true;
    }

    // Sets the minimum signer balance target for reimbursement decisions.
    function SetSignerMinBalance(uint256 _amount) public ownerOnly returns(bool){

        if(_amount > maxSignerMinBalance)
            revert InvalidAmount();

        signerMinBalance = _amount;

        emit SignerMinBalanceSet(_amount);

        return true;
    }

    // Sets the signer reimbursement cap paid for one withdrawal.
    function SetReimbursePerWithdraw(uint256 _amount) public ownerOnly returns(bool){

        if(_amount > maxReimbursePerWithdraw)
            revert InvalidAmount();

        reimbursePerWithdraw = _amount;

        emit ReimbursePerWithdrawSet(_amount);

        return true;
    }

    // Registers or updates the caller's service key and signer wallet without clearing balances.
    function RegisterClient(bytes calldata _hash, address _signer) public payable nonReentrant returns(bool){

        if(_signer == address(0))
            revert ZeroAddress();
        if(_signer.code.length != 0)
            revert InvalidSigner();

        address currentSigner = clients[msg.sender].signer;
        uint256 requiredFund = currentSigner == _signer ? 0 : signerFundAmount;

        if(msg.value != requiredFund)
            revert InvalidFee();

        Client storage client = clients[msg.sender];

        client.key = sha256(abi.encodePacked(msg.sender, _hash));
        client.signer = _signer;

        if(requiredFund > 0){

            (bool ok, ) = payable(_signer).call{value : requiredFund}("");

            if(!ok)
                revert TransferFailed();
        }

        emit Registered(msg.sender, _signer);

        return true;
    }

    // Lets a player deposit tokens to a server owner's balance.
    function Topup(address _to, string calldata _symbol, uint32 _amount, uint8 _server, string calldata _character) public payable nonReentrant returns(bool){

        address tokenAddress_ = tokenAddress[_symbol];
        Token memory token = tokenInfo[tokenAddress_];

        if(_amount == 0)
            revert InvalidAmount();
        if(msg.value != polFeeFlat)
            revert InvalidFee();
        if(!token.added || !token.topupEnabled)
            revert UnsupportedToken();
        if(clients[_to].signer == address(0))
            revert ClientNotRegistered();

        _redirectPolFeeIfCapped(msg.value);

        uint256 depositAmount = uint256(_amount) * (10 ** token.decimals);
        uint256 balanceBefore = IERC20(tokenAddress_).balanceOf(address(this));

        _safeTransferFrom(tokenAddress_, msg.sender, address(this), depositAmount);

        uint256 balanceAfter = IERC20(tokenAddress_).balanceOf(address(this));

        if(balanceAfter < balanceBefore || balanceAfter - balanceBefore != depositAmount)
            revert TransferFailed();

        clients[_to].balance[tokenAddress_] += _amount;

        emit Deposit(msg.sender, _to, _symbol, _amount, _server, _character);

        return true;
    }

    // Lets the registered signer submit a player withdrawal from the client balance.
    function Withdraw(address _from, address _to, string calldata _symbol, uint32 _amount, uint8 _server, string calldata _character, uint32 _refund) public nonReentrant returns(bool){

        uint256 gasStart = gasleft();
        address signer = clients[_from].signer;

        if(_amount == 0)
            revert InvalidAmount();
        if(_to == address(0))
            revert ZeroAddress();
        if(signer == address(0))
            revert ClientNotRegistered();
        if(msg.sender != signer)
            revert InvalidSigner();
        if(_refund < uint32(block.timestamp))
            revert Expired();

        _withdrawBalance(tokenAddress[_symbol], _from, _amount, _to, proxy.Owner());

        emit Withdrawal(_from, _to, _symbol, _amount, _server, _character, _refund);

        // Adds a small overhead estimate for reimbursement call, event, and function cleanup gas.
        _reimburseSigner(signer, (gasStart - gasleft() + 30000) * tx.gasprice);

        return true;
    }

    // Lets clients withdraw their own Service balance by canonical token address.
    function Claim(address _token, uint32 _amount) public nonReentrant returns(bool){

        if(_amount == 0)
            revert InvalidAmount();

        (, uint256 claimAmount, uint256 feeAmount) = _withdrawBalance(_token, msg.sender, _amount, msg.sender, proxy.Owner());

        emit DirectWithdraw(msg.sender, _token, _amount, claimAmount, feeAmount);

        return true;
    }

    // Lets the owner withdraw accumulated native POL from topup fees.
    function WithdrawPol(address _to, uint256 _amount) public ownerOnly nonReentrant returns(bool){

        if(_to == address(0))
            revert ZeroAddress();
        if(address(this).balance < _amount)
            revert InsufficientBalance();

        (bool ok, ) = payable(_to).call{value : _amount}("");

        if(!ok)
            revert TransferFailed();

        emit PolWithdrawn(_to, _amount);

        return true;
    }

//-----------------------------------------------------------------------// v DEFAULTS

    // Accepts native POL sent directly to the contract.
    receive() external payable {}

    // Accepts native POL sent with unknown calldata.
    fallback() external payable{}
}
