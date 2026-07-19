// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import { Events } from "../libraries/Events.sol";

abstract contract ClaimsMixin {
    struct Claim {
        address user;
        uint128 shares;
        bool immediate;
        bool settled;
        uint40 ts;
    }
    uint256 public nextClaimId;
    mapping(uint256 => Claim) public claims;
    uint256[] public queue;
    uint256 public head;
    uint256 public pendingShares;

    function _enqueueClaim(address u, uint256 s, bool imm) internal returns (uint256 id) {
        require(s <= type(uint128).max, "ClaimsMixin: shares overflow");
        require(block.timestamp <= type(uint40).max, "ClaimsMixin: timestamp overflow");
        // casting to uint128 and uint40 is safe because overflow is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        id = ++nextClaimId;
        claims[id] = Claim(u, uint128(s), imm, false, uint40(block.timestamp));
        queue.push(id);
        pendingShares += s;
        emit Events.ClaimRequested(id, u, s, imm);

        emit Events.SharesFrozen(u, s, id);
        emit Events.ClaimQueued(id);
    }

    function _cancelClaim(uint256 id, address caller) internal returns (uint256 s) {
        // emit after we restore shares in Core

        Claim storage c = claims[id];
        require(c.user == caller, "NOT_OWNER");
        require(!c.settled, "ALREADY");
        c.settled = true;
        s = c.shares;
        c.shares = 0;
        emit Events.ClaimCancelled(id, caller);
    }

    function _pop(uint256 max) internal returns (uint256[] memory ids) {
        emit Events.ClaimDequeued(queue[head]);

        uint256 n = queue.length;
        uint256 r = n > head ? n - head : 0;
        uint256 t = r < max ? r : max;
        ids = new uint256[](t);
        for (uint256 i = 0; i < t; i++) {
            ids[i] = queue[head + i];
        }
        head += t;
    }
}
