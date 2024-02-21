/**
 *Submitted for verification at PolygonScan.com on 2023-04-10
*/

//SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IChainlink{

	function latestAnswer() external view returns(int256);
    function decimals() external view returns(uint8);
}

contract BNBPrice{

//-----------------------------------------------------------------------// v EVENTS

//-----------------------------------------------------------------------// v INTERFACES

    IChainlink constant private chainLink = IChainlink(priceAddress);

//-----------------------------------------------------------------------// v BOOLEANS

//-----------------------------------------------------------------------// v ADDRESSES

    address constant private priceAddress = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

//-----------------------------------------------------------------------// v NUMBERS

//-----------------------------------------------------------------------// v BYTES

//-----------------------------------------------------------------------// v STRINGS

    string constant public Name = ".BNBPrice";

//-----------------------------------------------------------------------// v STRUCTS

//-----------------------------------------------------------------------// v ENUMS

//-----------------------------------------------------------------------// v MAPPINGS

//-----------------------------------------------------------------------// v MODIFIERS

//-----------------------------------------------------------------------// v CONSTRUCTOR

//-----------------------------------------------------------------------// v PRIVATE FUNCTIONS

//-----------------------------------------------------------------------// v GET FUNCTIONS

    function Price() public view returns(uint256){

        int256 answer = chainLink.latestAnswer();

        if(answer <=0)
            return(0);

        return(uint256(answer));
    }

    function Decimals() public view returns(uint8){

        return(chainLink.decimals());
    }
//-----------------------------------------------------------------------// v SET FUNTIONS

//-----------------------------------------------------------------------// v DEFAULTS

    fallback() external{}
}