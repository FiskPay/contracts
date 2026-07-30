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

    // Emitted when a client withdraws POL from its own signer gas tank.
    event GasTankWithdrawal(address indexed client, address indexed to, uint256 amount);

//-----------------------------------------------------------------------// v INTERFACES

    IProxy constant private proxy = IProxy(proxyAddress);

//-----------------------------------------------------------------------// v BOOLEANS

    bool private locked;                                // Reentrancy guard status.

//-----------------------------------------------------------------------// v ADDRESSES

    address constant private proxyAddress = 0xFCE63f00cC7b6BC7DDE11D9A4B00EDD1FD2c2dc6;
    address private subscriptionToken = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; // Native Polygon USDC by default.

//-----------------------------------------------------------------------// v NUMBERS

    uint8 private subscriptionTokenDecimals = 6;            // Cached decimals for the ERC20 token used for subscription payments.
    uint8 constant private subscriptionPlanSlots = 5;       // Fixed number of subscription plan slots; valid external plan IDs are 1 through 5.
    uint32 constant private freeTrialDays = 30;             // Free subscription days granted only on first registration.
    uint32 constant private subscriptionRenewalDays = 15;   // Allows renewal during the final 15 days before expiration or any time after expiration.

    uint256 private signerBalanceTarget = 2 ether;      // Current target POL balance for each client signer.
    uint256 private clientGasTankLimit = 10 ether;      // Current POL limit stored in one client's gas tank.

    uint256 constant private maxSignerBalanceTarget = 10 ether;     // Maximum allowed signer balance target.
    uint256 constant private maxClientGasTankLimit = 50 ether;      // Maximum allowed per-client gas tank limit.

//-----------------------------------------------------------------------// v STRINGS

    string constant public Name = "Service";
    address[] private tokens;					// Token addresses are canonical; symbols can change.

//-----------------------------------------------------------------------// v STRUCTS

    struct Client{

        bytes32 key;                            // Service login key derived from client wallet and signup hash.
        address signer;                         // Hot wallet allowed to submit this client's player withdrawals.
        uint256 gasTank;                        // Client-owned POL reserved for signer funding.
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
    error RenewalTooEarly();
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

//-----------------------------------------------------------------------// v OTHERS

    Plan[5] private subscriptionPlans;          // Stores five editable subscription plan slots.

//-----------------------------------------------------------------------// v CONSTRUCTOR

    constructor(){

        // Initializes the five fixed subscription slots; slot 5 starts disabled and can be configured later.
        subscriptionPlans[0] = Plan(10, 30, true);
        subscriptionPlans[1] = Plan(15, 60, true);
        subscriptionPlans[2] = Plan(50, 180, true);
        subscriptionPlans[3] = Plan(90, 365, true);
        subscriptionPlans[4] = Plan(0, 0, false);
    }

//-----------------------------------------------------------------------// v PRIVATE FUNCTIONS

    // Validates an external plan ID and converts its 1-based value into a zero-based fixed-array index.
    function _subscriptionPlanIndex(uint8 _planId) private pure returns(uint256){

        if(_planId == 0 || _planId > subscriptionPlanSlots)
            revert InvalidPlan();

        return uint256(_planId - 1);
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

    // Funds a signer from its client's stored gas tank until the signer reaches the configured target.
    function _fundSignerFromGasTank(Client storage _client, address _signer) private{

        uint256 signerBalance = _signer.balance;
        uint256 target = signerBalanceTarget;

        if(signerBalance >= target)
            return;

        uint256 amount = _client.gasTank;

        if(amount == 0)
            return;

        uint256 signerNeed = target - signerBalance;

        if(amount > signerNeed)
            amount = signerNeed;

        _client.gasTank -= amount;

        _sendPol(_signer, amount);
    }

    // Calculates the POL needed to bring one signer wallet up to the configured target.
    function _signerFundingAmount(address _signer) private view returns(uint256){

        uint256 target = signerBalanceTarget;
        uint256 signerBalance = _signer.balance;

        return signerBalance < target ? target - signerBalance : 0;
    }

    // Calculates the first-registration POL amount needed to fill the signer up to target plus the client gas tank.
    function _registrationAmount(address _signer) private view returns(uint256){

        return _signerFundingAmount(_signer) + clientGasTankLimit;
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

    // Returns the current POL limit each client can keep in its gas tank.
    function GetClientGasTankLimit() public view returns(uint256){

        return clientGasTankLimit;
    }

    // Returns the maximum allowed clientGasTankLimit.
    function GetMaxClientGasTankLimit() public pure returns(uint256){

        return maxClientGasTankLimit;
    }

    // Returns the signer POL balance target.
    function GetSignerBalanceTarget() public view returns(uint256){

        return signerBalanceTarget;
    }

    // Returns the maximum allowed signerBalanceTarget.
    function GetMaxSignerBalanceTarget() public pure returns(uint256){

        return maxSignerBalanceTarget;
    }

    // Returns the POL required only for first registration: missing signer POL plus full client gas tank.
    function GetRegistrationAmount(address _signer) public view returns(uint256){

        return _registrationAmount(_signer);
    }

    // Returns the POL required when an existing client changes to this signer.
    function GetSignerFundingAmount(address _signer) public view returns(uint256){

        return _signerFundingAmount(_signer);
    }

    // Returns POL owned by a client for future signer funding or manual withdrawal.
    function GetClientGasTank(address _client) public view returns(uint256){

        return clients[_client].gasTank;
    }

    // Returns the client gas tank fill level from 0 to 10000 for UI display.
    function GetClientGasTankLevel(address _client) public view returns(uint16){

        uint256 gasTank = clients[_client].gasTank;
        uint256 limit = clientGasTankLimit;

        if(gasTank == 0)
            return 0;
        if(gasTank >= limit)
            return 10000;

        return uint16(gasTank * 10000 / limit);
    }

    // Returns the ERC20 token accepted for subscription payments.
    function GetSubscriptionToken() public view returns(address){

        return subscriptionToken;
    }

    // Returns cached decimals for the subscription token.
    function GetSubscriptionTokenDecimals() public view returns(uint8){

        return subscriptionTokenDecimals;
    }

    // Returns the price, duration and enabled status of one fixed subscription slot.
    function GetSubscriptionPlan(uint8 _planId) public view returns(uint256 price, uint32 daysCount, bool enabled){

        Plan memory plan = subscriptionPlans[_subscriptionPlanIndex(_planId)];

        return (plan.price, plan.daysCount, plan.enabled);
    }

    // Returns all five fixed subscription slots, including disabled and unconfigured slots.
    function GetSubscriptionPlans() public view returns(uint256[subscriptionPlanSlots] memory prices, uint32[subscriptionPlanSlots] memory daysCounts, bool[subscriptionPlanSlots] memory enabled){

        for(uint256 i = 0; i < subscriptionPlanSlots; i++){

            Plan memory plan = subscriptionPlans[i];

            prices[i] = plan.price;
            daysCounts[i] = plan.daysCount;
            enabled[i] = plan.enabled;
    }
}

    // Returns enabled subscription plans in array form for frontend display.
    function GetActiveSubscriptionPlans() public view returns(uint8[] memory ids, uint256[] memory prices, uint32[] memory daysCounts){

        uint256 activeCount = 0;

        for(uint256 i = 0; i < subscriptionPlanSlots; i++){

            if(subscriptionPlans[i].enabled)
                activeCount++;
        }

        ids = new uint8[](activeCount);
        prices = new uint256[](activeCount);
        daysCounts = new uint32[](activeCount);

        uint256 index = 0;

        for(uint256 i = 0; i < subscriptionPlanSlots; i++){

            Plan memory plan = subscriptionPlans[i];

            if(!plan.enabled)
                continue;

            ids[index] = uint8(i + 1);
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

    // Sets the signer POL balance target.
    function SetSignerBalanceTarget(uint256 _amount) public ownerOnly returns(bool){

        if(_amount > maxSignerBalanceTarget)
            revert InvalidAmount();

        signerBalanceTarget = _amount;

        return true;
    }

    // Sets the maximum POL amount each client can store for signer funding.
    function SetClientGasTankLimit(uint256 _amount) public ownerOnly returns(bool){

        if(_amount == 0 || _amount > maxClientGasTankLimit)
            revert InvalidAmount();

        clientGasTankLimit = _amount;

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

    // Edits one of the five fixed subscription slots and controls whether clients can purchase it.
    function SetSubscriptionPlan(uint8 _planId, uint256 _price, uint32 _daysCount, bool _enabled) public ownerOnly returns(bool){

        if(_enabled && (_price == 0 || _daysCount == 0))
            revert InvalidAmount();

        subscriptionPlans[_subscriptionPlanIndex(_planId)] = Plan(_price, _daysCount, _enabled);

        return true;
    }

    // Lets a registered client purchase time from one enabled fixed subscription slot.
    // An active subscription may be renewed only during its final 15 days.
    function PaySubscription(uint8 _planId) public nonReentrant returns(bool){

        Client storage client = clients[msg.sender];

        if(client.signer == address(0))
            revert ClientNotRegistered();

        Plan memory plan = subscriptionPlans[_subscriptionPlanIndex(_planId)];

        if(!plan.enabled)
            revert InvalidPlan();

        uint256 currentExpiration = client.subscriptionExpiresAt;

        // Reject renewal while more than 15 days remain.
        if(currentExpiration > block.timestamp + uint256(subscriptionRenewalDays) * 1 days)
            revert RenewalTooEarly();

        uint256 paymentAmount = _subscriptionPriceToBase(plan.price);
        address owner = proxy.Owner();
        address token = subscriptionToken;

        _safeTransferFrom(token, msg.sender, owner, paymentAmount);

        uint256 start = currentExpiration;

        // Active subscriptions extend from their current expiration.
        // Expired subscriptions restart from the current timestamp.
        if(start < block.timestamp)
            start = block.timestamp;

        uint256 expiresAt = start + uint256(plan.daysCount) * 1 days;

        if(expiresAt > type(uint64).max)
            revert InvalidAmount();

        client.subscriptionExpiresAt = uint64(expiresAt);

        return true;
    }

    // Registers or updates the caller's service key and signer wallet without clearing balances.
    // First registration must fully fund the signer balance target and the client's gas tank.
    function RegisterClient(bytes calldata _hash, address _signer) public payable nonReentrant returns(bool){

        if(_signer == address(0))
            revert ZeroAddress();
        if(_signer.code.length != 0)
            revert InvalidSigner();

        Client storage client = clients[msg.sender];
        address currentSigner = client.signer;
        bool firstRegistration = currentSigner == address(0);
        bool signerChanged = currentSigner != _signer;
        uint256 requiredAmount = firstRegistration ? _registrationAmount(_signer) : signerChanged ? _signerFundingAmount(_signer) : 0;

        if(msg.value != requiredAmount)
            revert InvalidFee();

        client.key = sha256(abi.encodePacked(msg.sender, _hash));
        client.signer = _signer;

        if(firstRegistration){
            client.gasTank = clientGasTankLimit;
            client.subscriptionExpiresAt = uint64(block.timestamp + uint256(freeTrialDays) * 1 days);
        }

        _sendPol(_signer, requiredAmount - (firstRegistration ? clientGasTankLimit : 0));

        emit Registered(msg.sender, _signer);

        return true;
    }

    // Lets a player deposit tokens to a server owner's balance.
    function Topup(address _to, string calldata _symbol, uint32 _amount, uint8 _server, string calldata _character) public nonReentrant returns(bool){

        address tokenAddress_ = tokenAddress[_symbol];
        Token memory token = tokenInfo[tokenAddress_];

        if(_amount == 0)
            revert InvalidAmount();
        if(!token.added || !token.topupEnabled)
            revert UnsupportedToken();
        Client storage client = clients[_to];
        address signer = client.signer;

        if(signer == address(0))
            revert ClientNotRegistered();
        if(!IsClientSubscriptionActive(_to))
            revert SubscriptionExpired();

        _depositBalance(tokenAddress_, token.decimals, _to, _amount);

        emit Deposit(msg.sender, _to, _symbol, _amount, _server, _character);

        return true;
    }

    // Lets the registered signer submit a player withdrawal from the client balance.
    function Withdraw(address _from, address _to, string calldata _symbol, uint32 _amount, uint8 _server, string calldata _character, uint32 _refund) public nonReentrant returns(bool){

        Client storage client = clients[_from];
        address signer = client.signer;

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
        _fundSignerFromGasTank(client, signer);

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

    // Lets registered clients add POL to their own signer gas tank.
    function DepositGasTank() public payable nonReentrant returns(bool){

        if(msg.value == 0)
            revert InvalidAmount();
        Client storage client = clients[msg.sender];

        if(client.signer == address(0))
            revert ClientNotRegistered();

        uint256 gasTank = client.gasTank;
        uint256 limit = clientGasTankLimit;

        if(gasTank >= limit || msg.value > limit - gasTank)
            revert InvalidAmount();

        unchecked{ client.gasTank = gasTank + msg.value; }

        return true;
    }

    // Lets registered clients refill their signer from their own gas tank.
    function FundSignerFromGasTank() public nonReentrant returns(bool){

        Client storage client = clients[msg.sender];
        address signer = client.signer;

        if(signer == address(0))
            revert ClientNotRegistered();

        _fundSignerFromGasTank(client, signer);

        return true;
    }

    // Lets clients withdraw POL from their own gas tank.
    function WithdrawGasTank(address _to, uint256 _amount) public nonReentrant returns(bool){

        if(_to == address(0))
            revert ZeroAddress();
        if(_amount == 0)
            revert InvalidAmount();
        Client storage client = clients[msg.sender];

        if(client.gasTank < _amount)
            revert InsufficientBalance();

        client.gasTank -= _amount;

        _sendPol(_to, _amount);

        emit GasTankWithdrawal(msg.sender, _to, _amount);

        return true;
    }

//-----------------------------------------------------------------------// v DEFAULTS

    // Blocks direct POL sends because accepted POL must use registration or gas tank functions.
    receive() external payable {

        revert InvalidAmount();
    }

    // Blocks unknown calldata and accidental POL sends.
    fallback() external payable{

        revert InvalidAmount();
    }
}
