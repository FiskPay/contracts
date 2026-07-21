//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

interface IProxy{

    // Returns the protocol owner used for admin actions.
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

    // Emitted when a client registers or updates its signer wallet.
    event Registered(address indexed client, address indexed signer);

    // Emitted when a player deposits tokens into a client's service balance.
    event Deposit(address indexed from, address indexed to, string symbol, uint32 amount, uint8 server, string character);

    // Emitted when a registered signer withdraws tokens from a client's balance to a player.
    event Withdrawal(address indexed from, address indexed to, string symbol, uint32 amount, uint8 server, string character, uint32 refund);

    // Emitted when a client directly claims tokens from its own service balance.
    event DirectWithdrawal(address indexed client, address indexed token, uint32 amount, uint256 claimed);

    // Emitted when a client withdraws POL from its own signer gas balance.
    event GasBalanceWithdrawal(address indexed client, address indexed to, uint256 amount);

//-----------------------------------------------------------------------// v INTERFACES

    IProxy constant private proxy = IProxy(proxyAddress);

//-----------------------------------------------------------------------// v BOOLEANS

    bool private locked;                                // Reentrancy guard status.

//-----------------------------------------------------------------------// v ADDRESSES

    address constant private proxyAddress = 0xFCE63f00cC7b6BC7DDE11D9A4B00EDD1FD2c2dc6;
    address private subscriptionToken = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; // Native Polygon USDC by default.

//-----------------------------------------------------------------------// v NUMBERS

    uint32[] private subscriptionPlanIds;               // All plan IDs ever created, including disabled plans.

    uint32 private nextSubscriptionPlanId = 1;          // Next stable ID assigned to a new subscription plan.
    uint8 private subscriptionTokenDecimals = 6;        // Cached decimals for subscription payment token.
    uint32 constant private freeTrialDays = 30;         // Free subscription days granted only on first registration.

    uint256 private polFee = 0.125 ether;           // Native POL fee paid by players to support signer gas.
    uint256 private signerFundAmount = 1 ether;         // POL sent to a new signer wallet during registration.
    uint256 private signerBalanceTarget = 4 ether;      // Current target POL balance for each client signer.
    uint256 private clientGasBalanceLimit = 8 ether;    // Current POL limit stored in one client's gas balance.

    uint256 constant private maxPolFee = 5 ether;               // Maximum allowed POL topup fee.
    uint256 constant private maxSignerFundAmount = 10 ether;        // Maximum allowed initial signer funding.
    uint256 constant private maxSignerBalanceTarget = 10 ether;     // Maximum allowed signer balance target.
    uint256 constant private maxClientGasBalanceLimit = 20 ether;   // Maximum allowed per-client gas balance limit.

//-----------------------------------------------------------------------// v STRINGS

    string constant public Name = "Service";
    address[] private tokens;					// Token addresses are canonical; symbols can change.

//-----------------------------------------------------------------------// v STRUCTS

    struct Client{

        bytes32 key;                            // Service login key derived from client wallet and signup hash.
        address signer;                         // Hot wallet allowed to submit this client's player withdrawals.
        uint256 gasBalance;                     // Client-owned POL reserved for signer funding.
        uint64 subscriptionExpiresAt;           // Unix timestamp until which player topups are enabled for this client.
        mapping(address => uint32) balance;     // Client-owned token balances held by this contract, keyed by token address.
    }

    struct Plan{

        uint256 price;                          // Whole subscription tokens; with USDC, 1 means 1 USDC.
        uint32 daysCount;                       // Number of days added when the plan is purchased.
        bool enabled;                           // Disabled plans remain stored but cannot be bought.
    }

    struct Token{

        bool added;                             // Distinguishes a real token from an empty mapping slot.
        bool topupEnabled;                      // Blocks new deposits only; withdrawals remain available.
        uint8 decimals;                         // Cached once to avoid repeated token calls in hot paths.
        string symbol;                          // Display/lookup symbol; balances do not depend on this.
    }

//-----------------------------------------------------------------------// v MAPPINGS

    mapping(address => Client) private clients;         // Client wallet => client data.
    mapping(address => Token) private tokenInfo;        // Token address => token config.
    mapping(string => address) private tokenAddress;    // Current token symbol => token address.
    mapping(uint32 => Plan) private subscriptionPlans; // Stable plan ID => plan data.

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
    error SubscriptionExpired();
    error InvalidPlan();
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

//-----------------------------------------------------------------------// v CONSTRUCTOR

    constructor(){

        _addSubscriptionPlan(5, 14);
        _addSubscriptionPlan(10, 30);
        _addSubscriptionPlan(15, 60);
    }

//-----------------------------------------------------------------------// v PRIVATE FUNCTIONS

    // Stores a new enabled subscription plan and advances the next stable plan ID.
    function _addSubscriptionPlan(uint256 _price, uint32 _daysCount) private returns(uint32 planId){

        planId = nextSubscriptionPlanId;
        nextSubscriptionPlanId++;

        subscriptionPlans[planId] = Plan(_price, _daysCount, true);
        subscriptionPlanIds.push(planId);
    }

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

    // Sends native POL and reverts if the receiver rejects it.
    function _sendPol(address _to, uint256 _amount) private{

        if(_amount == 0)
            return;

        (bool ok, ) = payable(_to).call{value : _amount}("");

        if(!ok)
            revert TransferFailed();
    }

    // Shared balance withdrawal logic used by player withdrawals and direct client claims.
    function _withdrawBalance(address _token, address _client, uint32 _amount, address _to) private returns(uint256 totalAmount){

        Token memory token = tokenInfo[_token];

        if(!token.added)
            revert UnsupportedToken();
        if(clients[_client].balance[_token] < _amount)
            revert InsufficientBalance();

        totalAmount = uint256(_amount) * (10 ** token.decimals);

        // Effects happen before token transfers to reduce reentrancy risk.
        clients[_client].balance[_token] -= _amount;

        _safeTransfer(_token, _to, totalAmount);
    }

    // Pulls topup tokens into the contract and credits the client only after exact receipt.
    function _depositBalance(address _token, uint8 _decimals, address _client, uint32 _amount) private{

        uint256 depositAmount = uint256(_amount) * (10 ** _decimals);
        uint256 balanceBefore = IERC20(_token).balanceOf(address(this));

        _safeTransferFrom(_token, msg.sender, address(this), depositAmount);

        uint256 balanceAfter = IERC20(_token).balanceOf(address(this));

        if(balanceAfter < balanceBefore || balanceAfter - balanceBefore != depositAmount)
            revert TransferFailed();

        clients[_client].balance[_token] += _amount;
    }

    // Converts whole-token subscription prices into the token's smallest base units.
    function _subscriptionPriceToBase(uint256 _price) private view returns(uint256){

        return _price * (10 ** subscriptionTokenDecimals);
    }

    // Uses topup POL to fund the signer first, then client gas balance, then returns excess to the player.
    function _handleTopupGas(Client storage _client, address _signer, address _payer, uint256 _amount) private{

        if(_amount == 0)
            return;

        uint256 remaining = _amount;
        uint256 signerBalance = _signer.balance;
        uint256 target = signerBalanceTarget;

        if(signerBalance < target){

            uint256 signerFund = target - signerBalance;

            if(signerFund > remaining)
                signerFund = remaining;

            unchecked{ remaining -= signerFund; }
            _sendPol(_signer, signerFund);
        }

        if(remaining == 0)
            return;

        uint256 gasBalance = _client.gasBalance;
        uint256 limit = clientGasBalanceLimit;

        if(gasBalance < limit){

            uint256 credit = limit - gasBalance;

            if(credit > remaining)
                credit = remaining;

            unchecked{
                _client.gasBalance = gasBalance + credit;
                remaining -= credit;
            }
        }

        if(remaining > 0)
            _sendPol(_payer, remaining);
    }

    // Funds a signer from its client's stored gas balance until the signer reaches the configured cap.
    function _fundSignerFromClientGas(address _client, address _signer) private{

        uint256 signerBalance = _signer.balance;
        uint256 target = signerBalanceTarget;

        if(signerBalance >= target)
            return;

        Client storage client = clients[_client];
        uint256 amount = client.gasBalance;

        if(amount == 0)
            return;

        uint256 signerNeed = target - signerBalance;

        if(amount > signerNeed)
            amount = signerNeed;

        client.gasBalance -= amount;

        _sendPol(_signer, amount);
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

    // Returns the POL topup fee players must pay.
    function GetPolFee() public view returns(uint256){

        return polFee;
    }

    // Returns the maximum allowed polFee.
    function GetMaxPolFee() public pure returns(uint256){

        return maxPolFee;
    }

    // Returns the current POL limit each client can keep in its gas balance.
    function GetClientGasBalanceLimit() public view returns(uint256){

        return clientGasBalanceLimit;
    }

    // Returns the maximum allowed clientGasBalanceLimit.
    function GetMaxClientGasBalanceLimit() public pure returns(uint256){

        return maxClientGasBalanceLimit;
    }

    // Returns the POL amount sent to a new signer during registration.
    function GetSignerFundAmount() public view returns(uint256){

        return signerFundAmount;
    }

    // Returns the maximum allowed signerFundAmount.
    function GetMaxSignerFundAmount() public pure returns(uint256){

        return maxSignerFundAmount;
    }

    // Returns the signer POL balance target.
    function GetSignerBalanceTarget() public view returns(uint256){

        return signerBalanceTarget;
    }

    // Returns the maximum allowed signerBalanceTarget.
    function GetMaxSignerBalanceTarget() public pure returns(uint256){

        return maxSignerBalanceTarget;
    }

    // Returns POL owned by a client for future signer funding or manual withdrawal.
    function GetClientGasBalance(address _client) public view returns(uint256){

        return clients[_client].gasBalance;
    }

    // Returns the ERC20 token accepted for subscription payments.
    function GetSubscriptionToken() public view returns(address){

        return subscriptionToken;
    }

    // Returns cached decimals for the subscription token.
    function GetSubscriptionTokenDecimals() public view returns(uint8){

        return subscriptionTokenDecimals;
    }

    // Returns one subscription plan by stable ID.
    function GetSubscriptionPlan(uint32 _planId) public view returns(uint256 price, uint32 daysCount, bool enabled){

        Plan memory plan = subscriptionPlans[_planId];

        return (plan.price, plan.daysCount, plan.enabled);
    }

    // Returns every plan ID ever created, including disabled plans.
    function GetSubscriptionPlanIds() public view returns(uint32[] memory){

        return subscriptionPlanIds;
    }

    // Returns enabled subscription plans in array form for frontend display.
    function GetActiveSubscriptionPlans() public view returns(uint32[] memory ids, uint256[] memory prices, uint32[] memory daysCounts){

        uint256 activeCount = 0;
        uint256 depth = subscriptionPlanIds.length;

        for(uint256 i = 0; i < depth; i++){

            if(subscriptionPlans[subscriptionPlanIds[i]].enabled)
                activeCount++;
        }

        ids = new uint32[](activeCount);
        prices = new uint256[](activeCount);
        daysCounts = new uint32[](activeCount);

        uint256 index = 0;

        for(uint256 i = 0; i < depth; i++){

            uint32 planId = subscriptionPlanIds[i];
            Plan memory plan = subscriptionPlans[planId];

            if(!plan.enabled)
                continue;

            ids[index] = planId;
            prices[index] = plan.price;
            daysCounts[index] = plan.daysCount;
            index++;
        }
    }

    // Returns the timestamp when a client's subscription expires.
    function GetClientSubscriptionExpiresAt(address _client) public view returns(uint64){

        return clients[_client].subscriptionExpiresAt;
    }

    // Returns full days left in a client's current subscription.
    function GetClientSubscriptionDaysLeft(address _client) public view returns(uint32){

        uint64 expiresAt = clients[_client].subscriptionExpiresAt;

        if(expiresAt <= block.timestamp)
            return 0;

        return uint32((expiresAt - block.timestamp) / 1 days);
    }

    // Checks whether a client can currently receive player topups.
    function IsClientSubscriptionActive(address _client) public view returns(bool){

        return clients[_client].subscriptionExpiresAt > block.timestamp;
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
        if(_contract.code.length == 0)
            revert UnsupportedToken();
        if(tokenInfo[_contract].added)
            revert AlreadyAdded();

        IERC20 erc20 = IERC20(_contract);
        string memory symbol = erc20.symbol();

        if(tokenAddress[symbol] != address(0))
            revert AliasUsed();

        tokenInfo[_contract] = Token(true, true, erc20.decimals(), symbol);
        tokenAddress[symbol] = _contract;
        tokens.push(_contract);

        return true;
    }

    // Refreshes a known token symbol from the token contract after ticker changes.
    function UpdateTokenSymbol(address _contract) public ownerOnly returns(bool){

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

        return true;
    }

    // Enables or disables new topups only; existing balances stay withdrawable.
    function SetTokenTopupEnabled(address _contract, bool _enabled) public ownerOnly returns(bool){

        if(!tokenInfo[_contract].added)
            revert UnsupportedToken();

        tokenInfo[_contract].topupEnabled = _enabled;

        return true;
    }

    // Sets the native POL fee required on player topups.
    function SetPolFee(uint256 _amount) public ownerOnly returns(bool){

        if(_amount > maxPolFee)
            revert InvalidAmount();

        polFee = _amount;

        return true;
    }

    // Sets how much POL a new signer receives on registration or signer change.
    function SetSignerFundAmount(uint256 _amount) public ownerOnly returns(bool){

        if(_amount > maxSignerFundAmount)
            revert InvalidAmount();

        signerFundAmount = _amount;

        return true;
    }

    // Sets the signer POL balance target.
    function SetSignerBalanceTarget(uint256 _amount) public ownerOnly returns(bool){

        if(_amount > maxSignerBalanceTarget)
            revert InvalidAmount();

        signerBalanceTarget = _amount;

        return true;
    }

    // Sets the maximum POL amount each client can store for signer funding.
    function SetClientGasBalanceLimit(uint256 _amount) public ownerOnly returns(bool){

        if(_amount > maxClientGasBalanceLimit)
            revert InvalidAmount();

        clientGasBalanceLimit = _amount;

        return true;
    }

    // Sets the ERC20 token accepted for subscription payments and caches its decimals.
    function SetSubscriptionToken(address _token) public ownerOnly returns(bool){

        if(_token == address(0))
            revert ZeroAddress();
        if(_token.code.length == 0)
            revert UnsupportedToken();

        subscriptionToken = _token;
        subscriptionTokenDecimals = IERC20(_token).decimals();

        return true;
    }

    // Adds a new enabled subscription plan and returns its stable ID.
    function AddSubscriptionPlan(uint256 _price, uint32 _daysCount) public ownerOnly returns(uint32 planId){

        if(_price == 0 || _daysCount == 0)
            revert InvalidAmount();

        planId = _addSubscriptionPlan(_price, _daysCount);
    }

    // Updates an existing enabled subscription plan.
    function SetSubscriptionPlan(uint32 _planId, uint256 _price, uint32 _daysCount) public ownerOnly returns(bool){

        Plan storage plan = subscriptionPlans[_planId];

        if(!plan.enabled)
            revert InvalidPlan();
        if(_price == 0 || _daysCount == 0)
            revert InvalidAmount();

        plan.price = _price;
        plan.daysCount = _daysCount;

        return true;
    }

    // Disables a subscription plan without changing other plan IDs.
    function RemoveSubscriptionPlan(uint32 _planId) public ownerOnly returns(bool){

        Plan storage plan = subscriptionPlans[_planId];

        if(!plan.enabled)
            revert InvalidPlan();

        plan.enabled = false;

        return true;
    }

    // Lets a registered client buy subscription time using the configured subscription token.
    function PaySubscription(uint32 _planId) public nonReentrant returns(bool){

        if(clients[msg.sender].signer == address(0))
            revert ClientNotRegistered();

        Plan memory plan = subscriptionPlans[_planId];

        if(!plan.enabled)
            revert InvalidPlan();

        uint256 paymentAmount = _subscriptionPriceToBase(plan.price);
        address owner = proxy.Owner();
        address token = subscriptionToken;

        _safeTransferFrom(token, msg.sender, owner, paymentAmount);

        uint256 start = clients[msg.sender].subscriptionExpiresAt;

        if(start < block.timestamp)
            start = block.timestamp;

        uint256 expiresAt = start + uint256(plan.daysCount) * 1 days;

        if(expiresAt > type(uint64).max)
            revert InvalidAmount();

        clients[msg.sender].subscriptionExpiresAt = uint64(expiresAt);

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

        if(client.subscriptionExpiresAt == 0)
            client.subscriptionExpiresAt = uint64(block.timestamp + uint256(freeTrialDays) * 1 days);

        _sendPol(_signer, requiredFund);

        emit Registered(msg.sender, _signer);

        return true;
    }

    // Lets a player deposit tokens to a server owner's balance.
    function Topup(address _to, string calldata _symbol, uint32 _amount, uint8 _server, string calldata _character) public payable nonReentrant returns(bool){

        address tokenAddress_ = tokenAddress[_symbol];
        Token memory token = tokenInfo[tokenAddress_];

        if(_amount == 0)
            revert InvalidAmount();
        if(msg.value != polFee)
            revert InvalidFee();
        if(!token.added || !token.topupEnabled)
            revert UnsupportedToken();
        Client storage client = clients[_to];
        address signer = client.signer;

        if(signer == address(0))
            revert ClientNotRegistered();
        if(!IsClientSubscriptionActive(_to))
            revert SubscriptionExpired();

        _depositBalance(tokenAddress_, token.decimals, _to, _amount);
        _handleTopupGas(client, signer, msg.sender, msg.value);

        emit Deposit(msg.sender, _to, _symbol, _amount, _server, _character);

        return true;
    }

    // Lets the registered signer submit a player withdrawal from the client balance.
    function Withdraw(address _from, address _to, string calldata _symbol, uint32 _amount, uint8 _server, string calldata _character, uint32 _refund) public nonReentrant returns(bool){

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

        _withdrawBalance(tokenAddress[_symbol], _from, _amount, _to);
        _fundSignerFromClientGas(_from, signer);

        emit Withdrawal(_from, _to, _symbol, _amount, _server, _character, _refund);

        return true;
    }

    // Lets clients withdraw their own Service balance by canonical token address.
    function Claim(address _token, uint32 _amount) public nonReentrant returns(bool){

        if(_amount == 0)
            revert InvalidAmount();

        uint256 claimAmount = _withdrawBalance(_token, msg.sender, _amount, msg.sender);

        emit DirectWithdrawal(msg.sender, _token, _amount, claimAmount);

        return true;
    }

    // Lets clients withdraw POL from their own gas balance.
    function WithdrawGasBalance(address _to, uint256 _amount) public nonReentrant returns(bool){

        if(_to == address(0))
            revert ZeroAddress();
        if(_amount == 0)
            revert InvalidAmount();
        Client storage client = clients[msg.sender];

        if(client.gasBalance < _amount)
            revert InsufficientBalance();

        client.gasBalance -= _amount;

        _sendPol(_to, _amount);

        emit GasBalanceWithdrawal(msg.sender, _to, _amount);

        return true;
    }

//-----------------------------------------------------------------------// v DEFAULTS

    // Blocks direct POL sends because all accepted POL must belong to registration, topup, or gas withdrawal flows.
    receive() external payable {

        revert InvalidAmount();
    }

    // Blocks unknown calldata and accidental POL sends.
    fallback() external payable{

        revert InvalidAmount();
    }
}
