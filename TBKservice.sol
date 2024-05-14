//SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IProxy{

    function Owner() external view returns(address);
    function GetContractAddress(string calldata _name) external view returns(address);
}

interface IERC20{

    function decimals() external view returns (uint8);
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface ITBK{

    function GetAddress(string calldata symbol) external view returns(address);
    function GetBalance(string calldata symbol, address client) external view returns(uint32);
    function GetKey(string calldata symbol, address client) external view returns(bytes32);
    function DepositBalance(address token, address client, uint32 amount) external returns(bool);
    function WithdrawBalance(address token, address client, uint32 amount) external returns(bool);
    function SetKey(string calldata symbol, address client, bytes32 key) external returns(bool);
}

contract TBKservice{

//-----------------------------------------------------------------------// v EVENTS

    event Payout(address indexed to, string symbol, uint256 total, uint256 claimed, uint256 fee);
    event Deposit(address indexed from, address indexed to, string symbol, uint32 amount, uint8 server, string character);
    event Withdrawal(address indexed from, address indexed to, string symbol, uint32 amount, uint8 server, string character, uint32 refund);
 
//-----------------------------------------------------------------------// v INTERFACES

    IProxy constant private proxy = IProxy(proxyAddress);

//-----------------------------------------------------------------------// v BOOLEANS

//-----------------------------------------------------------------------// v ADDRESSES

    address constant private proxyAddress = 0xFCE63f00cC7b6BC7DDE11D9A4B00EDD1FD2c2dc6;
    address private managerAddress = 0xC33aeBe8e1E0217D85fb6730a9C371EF95bBC245;
    address private collectorAddress = proxy.Owner();

//-----------------------------------------------------------------------// v NUMBERS

//-----------------------------------------------------------------------// v BYTES

//-----------------------------------------------------------------------// v STRINGS

    string constant public Name = "TBKservice";

//-----------------------------------------------------------------------// v STRUCTS

//-----------------------------------------------------------------------// v ENUMS

//-----------------------------------------------------------------------// v MAPPINGS

    mapping(string => uint8) private feePerThousand;

//-----------------------------------------------------------------------// v MODIFIERS

    modifier ownerOnly() {

        require(proxy.Owner() == msg.sender);
        _;
    }

//-----------------------------------------------------------------------// v CONSTRUCTOR

//-----------------------------------------------------------------------// v INTERNAL FUNCTIONS

    function _claim(string calldata _symbol, uint32 _amount) private returns(uint256 totalAmount, uint256 claimAmount, uint256 feeAmount){

        require(_amount > 0, "Amount is zero");

        address tbkAddress = proxy.GetContractAddress("TBKdata");

        ITBK tbk = ITBK(tbkAddress);

        address erc20Address = tbk.GetAddress(_symbol);

        require(erc20Address != address(0), "Token unsupported");

        IERC20 erc20 = IERC20(erc20Address);

        totalAmount = _amount * (10 ** erc20.decimals());
        feeAmount = totalAmount * feePerThousand[_symbol] / 1000;
        claimAmount = totalAmount - feeAmount;

        require(tbk.GetBalance(_symbol, msg.sender)>= _amount, "Insufficient balance");

        tbk.WithdrawBalance(erc20Address, msg.sender, _amount);
        erc20.transfer(msg.sender, claimAmount);

        if(feeAmount > 0)
            erc20.transfer(collectorAddress, feeAmount);
    }

    function _topup(address _to, string calldata _symbol, uint32 _amount) private returns(uint32 topupAmount){
        
        require(_amount > 0, "Amount is zero");

        address tbkAddress = proxy.GetContractAddress("TBKdata");

        ITBK tbk = ITBK(tbkAddress);

        address erc20Address = tbk.GetAddress(_symbol);

        require(erc20Address != address(0), "Token unsupported");
        require(tbk.GetKey(_symbol, _to) != bytes32(0), "Client key not set");

        IERC20 erc20 = IERC20(erc20Address);

        uint256 depositAmount = _amount * (10 ** erc20.decimals());

        require(erc20.balanceOf(msg.sender) >= depositAmount, "Insufficient balance");
        require(erc20.allowance(msg.sender, address(this))>= depositAmount, "Transaction not approved");

        if(erc20.allowance(address(this), tbkAddress) < depositAmount)
            erc20.approve(tbkAddress, 2 ** 256 - 1);

        erc20.transferFrom(msg.sender, address(this), depositAmount);
        tbk.DepositBalance(erc20Address, _to, _amount);

        topupAmount = _amount;
    }

    function _withdraw(address _from, address _to, string calldata _symbol, uint32 _amount) private returns(uint32 withdrawAmount){
        
        require(_amount > 0, "Amount is zero");

        address tbkAddress = proxy.GetContractAddress("TBKdata");

        ITBK tbk = ITBK(tbkAddress);

        address erc20Address = tbk.GetAddress(_symbol);

        require(erc20Address != address(0), "Token unsupported");
        require(tbk.GetBalance(_symbol, _from)>= _amount, "Insufficient balance");

        IERC20 erc20 = IERC20(erc20Address);

        uint256 totalAmount = _amount * (10 ** erc20.decimals());
        uint256 feeAmount = totalAmount * feePerThousand[_symbol] / 1000;
        
        tbk.WithdrawBalance(erc20Address, _from, _amount);
        erc20.transfer(_to, totalAmount - feeAmount);

        if(feeAmount > 0)
            erc20.transfer(collectorAddress, feeAmount);
                         
        withdrawAmount = _amount;
    }

//-----------------------------------------------------------------------// v GET FUNCTIONS

    function TestWithdraw(address _from, string calldata _symbol, uint32 _amount) public view returns(bool){

        ITBK tbk = ITBK(proxy.GetContractAddress("TBKdata"));

        if(tbk.GetAddress(_symbol) == address(0))
            return false;

        return tbk.GetBalance(_symbol, _from) >= _amount;
    }

    function GetClientKey(string calldata _symbol, address _client)public view returns(bytes32){

        return ITBK(proxy.GetContractAddress("TBKdata")).GetKey(_symbol, _client);
    }

    function GetClientBalance(string calldata _symbol, address _client) public view returns(uint32){

        return ITBK(proxy.GetContractAddress("TBKdata")).GetBalance(_symbol, _client);
    }

    function GetTokenAddress(string calldata _symbol)public view returns(address){

        return ITBK(proxy.GetContractAddress("TBKdata")).GetAddress(_symbol);
    }

    function GetFee(string calldata _symbol) public view returns(uint8){

        return feePerThousand[_symbol];
    }
    
    function GetManager() public view returns(address){

        return managerAddress;
    }

    function GetCollector() public view returns(address){

        return collectorAddress;
    }

//-----------------------------------------------------------------------// v SET FUNTIONS

    function Claim(string calldata _symbol, uint32 _amount) public payable returns(bool){

        require(msg.value > 0, "Manager fee is zero");

        (uint256 totalAmount, uint256 claimAmount, uint256 feeAmount) = _claim(_symbol, _amount);
        payable(address(managerAddress)).call{value : msg.value}("");
                
        emit Payout(msg.sender, _symbol, totalAmount, claimAmount, feeAmount);

        return true;
    }
    
    function Topup(address _to, string calldata _symbol, uint32 _amount, uint8 _server, string calldata _character) public payable returns(bool){
        
        require(msg.value > 0, "Manager fee is zero");

        uint32 topupAmount = _topup(_to, _symbol, _amount);
        payable(address(managerAddress)).call{value : msg.value}("");

        emit Deposit(msg.sender, _to, _symbol, topupAmount, _server, _character);

        return true;
    }

    function Withdraw(address _from, address _to, string calldata _symbol, uint32 _amount,  uint8 _server, string calldata _character, uint32 _refund) public returns(bool){

        require(msg.sender == managerAddress);
        require(_refund >= uint32(block.timestamp), "Expired");
        
        uint32 withdrawAmount = _withdraw(_from, _to, _symbol, _amount);

        emit Withdrawal(_from, _to, _symbol, withdrawAmount, _server, _character, _refund);

        return true;
    }

    function SetClientKey(string calldata _symbol, bytes calldata _hash) public returns(bool){

        ITBK tbk = ITBK(proxy.GetContractAddress("TBKdata"));

        require(tbk.GetAddress(_symbol) != address(0), "Token unsupported");

        bytes32 key = sha256(abi.encodePacked(msg.sender, _hash));

        tbk.SetKey(_symbol, msg.sender, key);

        return true;
    }

    function SetFee(string calldata _symbol, uint8 _perThousand) public ownerOnly returns(bool){

        feePerThousand[_symbol] = _perThousand;

        return true;
    }
    
    function SetManager(address _address) public ownerOnly returns(bool){

        managerAddress = _address;

        return true;
    }

    function SetCollector(address _address) public ownerOnly returns(bool){

        collectorAddress = _address;

        return true;
    }

//-----------------------------------------------------------------------// v DEFAULTS

    receive() external payable {

        if(msg.value > 0)
            payable(address(managerAddress)).call{value : msg.value}("");
    }

    fallback() external payable{}
}