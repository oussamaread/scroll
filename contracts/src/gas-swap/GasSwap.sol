// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";

contract GasSwap is ERC2771Context, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Permit;

    event UpdateFeeRatio(uint256 feeRatio);
    event UpdateApprovedTarget(address target, bool status);

    uint256 private constant PRECISION = 1e18;

    struct PermitData {
        address token;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct SwapData {
        address target;
        bytes data;
        uint256 minOutput;
    }

    mapping(address => bool) public approvedTargets;

    uint256 public feeRatio;

    constructor(address trustedForwarder) ERC2771Context(trustedForwarder) {}

    receive() external payable {}

    function swap(PermitData memory _permit, SwapData memory _swap) external nonReentrant {
        require(approvedTargets[_swap.target], "Target not approved");
        address _sender = _msgSender();

        IERC20Permit(_permit.token).permit(
            _sender,
            address(this),
            _permit.value,
            _permit.deadline,
            _permit.v,
            _permit.r,
            _permit.s
        );

        uint256 _balanceBefore = IERC20(_permit.token).balanceOf(address(this));

        IERC20(_permit.token).safeTransferFrom(_sender, address(this), _permit.value);
        IERC20(_permit.token).safeApprove(_swap.target, 0);
        IERC20(_permit.token).safeApprove(_swap.target, _permit.value);

        uint256 _outputTokenAmountBefore = address(this).balance;
        (bool _success, bytes memory _res) = _swap.target.call(_swap.data);
        require(_success, string(abi.encodePacked("Swap failed: ", getRevertMsg(_res))));

        uint256 _outputTokenAmount = address(this).balance - _outputTokenAmountBefore;

        uint256 _fee = (_outputTokenAmount * feeRatio) / PRECISION;
        _outputTokenAmount -= _fee;
        require(_outputTokenAmount >= _swap.minOutput, "Insufficient output amount");

        (bool _ethTransferSuccess, ) = _sender.call{value: _outputTokenAmount}("");
        require(_ethTransferSuccess, "Transfer ETH failed");

        uint256 _dust = IERC20(_permit.token).balanceOf(address(this)) - _balanceBefore;
        if (_dust > 0) {
            IERC20(_permit.token).safeTransfer(_sender, _dust);
        }
    }

    function withdraw(address _token, uint256 _amount) external onlyOwner {
        if (_token == address(0)) {
            (bool _success, ) = _msgSender().call{value: _amount}("");
            require(_success, "ETH transfer failed");
        } else {
            IERC20(_token).safeTransfer(_msgSender(), _amount);
        }
    }

    function updateFeeRatio(uint256 _feeRatio) external onlyOwner {
        feeRatio = _feeRatio;
        emit UpdateFeeRatio(_feeRatio);
    }

    function updateApprovedTarget(address _target, bool _status) external onlyOwner {
        approvedTargets[_target] = _status;
        emit UpdateApprovedTarget(_target, _status);
    }

    function _msgData() internal view virtual override(ERC2771Context, Context) returns (bytes memory) {
        return ERC2771Context._msgData();
    }

    function _msgSender() internal view virtual override(ERC2771Context, Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    function getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        if (_returnData.length < 68) return "Transaction reverted silently";
        assembly {
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string));
    }
}
