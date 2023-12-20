//SPDX-License-Identifier: MIT

pragma solidity 0.8.22;

interface IProxy{

    function Owner() external view returns(address);
    function GetContractAddress(string calldata _name) external view returns(address);
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

    address constant private proxyAddress = 0xbceac0a87F1FB1db4C641E3B8De2b59B3397fD47;

//-----------------------------------------------------------------------// v NUMBERS

//-----------------------------------------------------------------------// v BYTES

//-----------------------------------------------------------------------// v STRINGS

    string constant public Name = "TBKdata";
    string[] private tokens;

//-----------------------------------------------------------------------// v STRUCTS

//-----------------------------------------------------------------------// v ENUMS

//-----------------------------------------------------------------------// v MAPPINGS

    mapping(string => address) private token;
    mapping(string => mapping(address => uint32)) private balance;
    mapping(string => mapping(address => bytes32)) private key;

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

        return token[_symbol];
    }

    function GetBalance(string calldata _symbol, address _client) public view returns(uint32){

        return balance[_symbol][_client];
    }

    function GetKey(string calldata _symbol, address _client) public view returns(bytes32){

        return key[_symbol][_client];
    }
//-----------------------------------------------------------------------// v SET FUNTIONS

    function AddToken(address _contract) public ownerOnly returns(bool){
        
        string memory symbol = IERC20(_contract).symbol();
        uint16 depth = uint16(tokens.length);
        uint16 i = 0;

        for(i; i < depth; i++){

            if(token[tokens[i]] == _contract)
                revert("Already added");
        }

        token[symbol] = _contract;
        tokens.push(symbol);

        return true;
    }

    function RemoveToken(string calldata _symbol) public ownerOnly returns(bool){

        require (tokens.length > 0, "No tokens");
        
        uint16 i = uint16(tokens.length - 1);
        string memory lastToken = tokens[i];

        for(i; i >= 0; i--){

            if(sha256(abi.encodePacked(tokens[i])) == sha256(abi.encodePacked(_symbol))){

                delete token[_symbol];
                tokens[i] = lastToken;
                tokens.pop();

                return true;
            }
        }

        revert("Already removed");
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

    function SetKey(string calldata _symbol, address _client, bytes32 _key) public serviceOnly returns(bool){

        key[_symbol][_client] = _key;

        return true;
    }

//-----------------------------------------------------------------------// v DEFAULTS

    receive() external payable {

        revert("Reverted receive");
    }

    fallback() external serviceOnly ownerOnly{}
}