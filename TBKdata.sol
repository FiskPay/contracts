//SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

interface IProxy{

    function Owner() external view returns(address);
    function GetContractAddress(string calldata name) external view returns(address);
}

interface IERC20{

    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract TBKdata{

//-----------------------------------------------------------------------// v EVENTS

//-----------------------------------------------------------------------// v INTERFACES

    IProxy constant private proxy = IProxy(proxyAddress);

//-----------------------------------------------------------------------// v BOOLEANS

//-----------------------------------------------------------------------// v ADDRESSES

    address constant private proxyAddress = 0xFCE63f00cC7b6BC7DDE11D9A4B00EDD1FD2c2dc6;

//-----------------------------------------------------------------------// v NUMBERS

    uint256 private polFee = 12500000000000000;

//-----------------------------------------------------------------------// v BYTES

//-----------------------------------------------------------------------// v STRINGS

    string constant public Name = "TBKdata";
    string[] private tokens;

//-----------------------------------------------------------------------// v STRUCTS

//-----------------------------------------------------------------------// v ENUMS

//-----------------------------------------------------------------------// v MAPPINGS

    mapping(string => address) private tokenAddress;
    mapping(string => uint8) private tokenFee;
    mapping(address => bytes32) private key;
    mapping(string => mapping(address => uint32)) private balance;

//-----------------------------------------------------------------------// v MODIFIERS

    modifier ownerOnly() {

        require(proxy.Owner() == msg.sender);
        _;
    }

    modifier serviceOnly() {

        require(proxy.GetContractAddress("TBKservice") == msg.sender);
        _;
    }

//-----------------------------------------------------------------------// v CONSTRUCTOR

//-----------------------------------------------------------------------// v INTERNAL FUNCTIONS

//-----------------------------------------------------------------------// v GET FUNCTIONS

    function GetTokens() public view returns(string[] memory){

        return tokens;
    }

    function GetAddress(string calldata _symbol) public view returns(address){

        return tokenAddress[_symbol];
    }

    function GetBalance(string calldata _symbol, address _client) public view returns(uint32){

        return balance[_symbol][_client];
    }

    function GetKey(address _client) public view returns(bytes32){

        return key[_client];
    }

    function GetTokenFee(string calldata _symbol) public view returns(uint8){

        return tokenFee[_symbol];
    }

    function GetPolFee() public view returns (uint256){

        return polFee;
    }
//-----------------------------------------------------------------------// v SET FUNTIONS

    function AddToken(address _contract) public ownerOnly returns(bool){
        
        string memory symbol = IERC20(_contract).symbol();
        uint16 depth = uint16(tokens.length);
        uint16 i = 0;

        for(i; i < depth; i++){

            if(tokenAddress[tokens[i]] == _contract)
                revert("Already added");
        }

        tokenAddress[symbol] = _contract;
        tokenFee[symbol] = 10;

        tokens.push(symbol);

        return true;
    }

    function RemoveToken(string calldata _symbol) public ownerOnly returns(bool){

        require (tokens.length > 0, "No tokens");
        
        uint16 i = uint16(tokens.length - 1);
        string memory lastToken = tokens[i];

        for(i; i >= 0; i--){

            if(sha256(abi.encodePacked(tokens[i])) == sha256(abi.encodePacked(_symbol))){

                delete tokenAddress[_symbol];
                delete tokenFee[_symbol];

                tokens[i] = lastToken;
                tokens.pop();

                return true;
            }
        }

        revert("Already removed");
    }

    function SetTokenFee(string calldata _symbol, uint8 _perThousand) public ownerOnly returns(bool){

        require(GetAddress(_symbol) != address(0), "Unsupported token");

        tokenFee[_symbol] = _perThousand;

        return true;
    }

    function SetPolFee(uint256 _amount) public ownerOnly returns(bool){

        polFee = _amount;

        return true;
    }

    function DepositBalance(address _token, address _client, uint32 _amount) public serviceOnly returns(bool){

        IERC20 erc20 = IERC20(_token);

        string memory symbol = erc20.symbol();
        uint8 decimals = erc20.decimals();
        uint256 totalAmount = _amount * (10 ** decimals);

        erc20.transferFrom(msg.sender, address(this), totalAmount);
        balance[symbol][_client] = balance[symbol][_client] + _amount;

        return true;
    }

    function WithdrawBalance(address _token, address _client, uint32 _amount) public serviceOnly returns(bool){

        IERC20 erc20 = IERC20(_token);

        string memory symbol = erc20.symbol();
        uint8 decimals = erc20.decimals();
        uint256 totalAmount = _amount * (10 ** decimals);

        require(balance[symbol][_client] >= _amount);

        balance[symbol][_client] = balance[symbol][_client] - _amount;
        erc20.transfer(msg.sender, totalAmount);

        return true;
    }

    function SetKey(address _client, bytes32 _key) public serviceOnly returns(bool){

        key[_client] = _key;

        return true;
    }

//-----------------------------------------------------------------------// v DEFAULTS

    receive() external payable {

        revert("Reverted receive");
    }

    fallback() external serviceOnly ownerOnly{}
}