// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Modulo Incentivi (Loyalty Boost) per CoreVault:
/// - Cliff (Tc) = 30d, Full (Tf) = 180d, Bmax = +3% APY (configurabili)
/// - Bonus maturato via formula chiusa (no loop giornalieri)
/// - Claim ΓåÆ crea tranche con vesting lineare (default 180d)
/// - onExit() slasha la parte non vestita a Treasury
/// - Pu├▓ essere disattivato: disabilita NUOVA maturazione/claim, ma le tranche esistenti restano ritirabili.
///
/// NOTE UNIT:
/// - Tutte le quantit├á espresse come WAD (1e18). Il Core effettua le conversioni (es. USDC 6 dec ΓåÆ 1e18).
/// - Il modulo NON muove fondi: ritorna numeri; il Core esegue i trasferimenti/mint/burn.

import { IIncentives } from "../../interfaces/IIncentives.sol";
import { FixedPoint } from "../../libs/FixedPoint.sol";

contract Incentives is IIncentives {
    // ---------------- FixedPoint 1e18 ----------------
    uint256 internal constant WAD = FixedPoint.WAD;

    function _wmul(uint256 x, uint256 y) internal pure returns (uint256) {
        return FixedPoint.mulWadDown(x, y);
    }

    function _wdiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return FixedPoint.divWadDown(x, y);
    }

    // ---------------- Access Control ----------------
    address public override core; // unico chiamante autorizzato alle funzioni mutative "utente"
    address public override treasury; // dove inviare la parte non vestita (contabilmente nel Core)

    address public owner; // admin/guardian (set parametri, core, treasury, active)
    modifier onlyOwner() {
        require(msg.sender == owner, "not-owner");
        _;
    }
    modifier onlyCore() {
        require(msg.sender == core, "not-core");
        _;
    }

    // ---------------- Params ----------------
    Params private _p; // parametri correnti
    bool private _active; // se false: nessuna nuova maturazione/claim; vesting esistenti OK

    function getParams() external view override returns (Params memory) {
        return _p;
    }

    function isActive() external view override returns (bool) {
        return _active;
    }

    // ---------------- Stato per utente ----------------
    struct Streak {
        uint256 startTs; // inizio permanenza continua
        uint256 lastAccrualTs; // ultimo checkpoint maturazione
        uint256 principalWad; // base di calcolo attuale (snapshot in WAD)
    }

    struct Vesting {
        uint256 amountWad; // importo totale della tranche
        uint256 startTs;
        uint256 duration; // in secondi
        uint256 withdrawnWad; // gi├á prelevato
        bool active;
    }

    mapping(address => Streak) public streaks;
    mapping(address => Vesting[]) private _vestings;

    // ---------------- Events ----------------
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event CoreSet(address indexed core);
    event TreasurySet(address indexed treasury);
    event ParamsSet(Params p);
    event ActiveSet(bool active);

    event StreakReset(address indexed user, uint256 ts);
    event BonusClaimed(address indexed user, uint256 amountWad, uint256 vestingIdx);
    event BonusWithdrawn(address indexed user, uint256 vestingIdx, uint256 amountWad);
    event UnvestedSlashed(address indexed user, uint256 vestingIdx, uint256 amountWad);

    // ---------------- Ctor ----------------
    constructor(address owner_, address core_, address treasury_, Params memory p_) {
        require(owner_ != address(0), "owner=0");
        require(core_ != address(0), "core=0"); // SECURITY: Validate core address
        require(treasury_ != address(0), "treasury=0"); // SECURITY: Validate treasury address
        owner = owner_;
        core = core_;
        treasury = treasury_;
        _setParams(p_);
        _active = true;

        emit OwnerChanged(address(0), owner_);
        emit CoreSet(core_);
        emit TreasurySet(treasury_);
        emit ParamsSet(p_);
        emit ActiveSet(true);
    }

    // ---------------- Admin ----------------
    function setCore(address core_) external override onlyOwner {
        require(core_ != address(0), "core=0");
        core = core_;
        emit CoreSet(core_);
    }

    function setTreasury(address treasury_) external override onlyOwner {
        require(treasury_ != address(0), "treasury=0");
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setParams(Params calldata p) external override onlyOwner {
        _setParams(p);
        emit ParamsSet(p);
    }

    function setActive(bool active_) external override onlyOwner {
        _active = active_;
        emit ActiveSet(active_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "newOwner=0");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function _setParams(Params memory p) internal {
        require(p.cliffDays > 0, "badTc");
        require(p.fullDays > p.cliffDays, "Tf<=Tc");
        require(p.bmaxWad <= 5e16, "Bmax>5%"); // guard-rail: max 5%
        require(p.vestingDays > 0 && p.vestingDays <= 365, "badVesting");
        _p = p;
    }

    // ---------------- Helpers tempo ----------------
    function _daysFrom(uint256 fromTs, uint256 toTs) internal pure returns (uint256) {
        require(toTs >= fromTs, "time");
        return (toTs - fromTs) / 1 days;
    }

    // ---------------- Formula Chiusa ----------------
    /// @notice Antiderivata F(t) della APY bonus (t in giorni) in 1e18.
    /// @dev Function name _F follows mathematical notation for antiderivative F(t)
    // m = Bmax/(Tf-Tc)
    function _calculateAntiderivative(uint256 tDays) internal view returns (uint256) {
        uint256 Tc = _p.cliffDays;
        uint256 Tf = _p.fullDays;
        if (tDays <= Tc) return 0;

        // SECURITY: Prevent division by zero if Tf == Tc
        if (Tf <= Tc) return 0;

        // m in 1e18 (WAD per giorno)
        uint256 m = _wdiv(_p.bmaxWad, (Tf - Tc) * WAD);

        if (tDays <= Tf) {
            uint256 dt = (tDays - Tc) * WAD; // 1e18 "giorni"
            uint256 term = (m * dt * dt) / (2 * WAD * WAD); // (m/2)*(t-Tc)^2 in 1e18
            return term;
        } else {
            uint256 dtFull = (Tf - Tc) * WAD; // 1e18 "giorni"
            uint256 rampArea = (m * dtFull * dtFull) / (2 * WAD * WAD); // (m/2)*(Tf-Tc)^2
            uint256 tailDays = (tDays - Tf) * WAD; // 1e18 "giorni"
            uint256 tailArea = _wmul(_p.bmaxWad, tailDays); // Bmax*(t-Tf)
            return rampArea + tailArea; // 1e18
        }
    }

    // bonus(A, [t1,t2]) = A * (F(t2)-F(t1)) / 365
    function _bonusAmount(uint256 principalWad, uint256 t1Days, uint256 t2Days)
        internal
        view
        returns (uint256)
    {
        if (t2Days <= t1Days) return 0;
        uint256 F1 = _calculateAntiderivative(t1Days);
        uint256 F2 = _calculateAntiderivative(t2Days);
        if (F2 <= F1) return 0;
        uint256 dF = F2 - F1; // 1e18
        uint256 num = _wmul(principalWad, dF); // 1e18
        return num / 365; // 1e18
    }

    // ---------------- Views pubbliche ----------------
    function vestingsCount(address user) external view returns (uint256) {
        return _vestings[user].length;
    }

    function currentTDays(address user) public view override returns (uint256) {
        Streak storage s = streaks[user];
        if (s.startTs == 0) return 0;
        return _daysFrom(s.startTs, block.timestamp);
    }

    function pendingBonus(address user) public view override returns (uint256) {
        if (!_active) return 0; // se spento, nessuna nuova maturazione
        Streak storage s = streaks[user];
        if (s.startTs == 0 || s.principalWad == 0) return 0;
        uint256 t1 = _daysFrom(s.startTs, s.lastAccrualTs);
        uint256 t2 = _daysFrom(s.startTs, block.timestamp);
        return _bonusAmount(s.principalWad, t1, t2);
    }

    function vestedAvailable(address user, uint256 idx) public view override returns (uint256) {
        Vesting storage v = _vestings[user][idx];
        if (!v.active) return 0;
        if (block.timestamp <= v.startTs) return 0;
        uint256 elapsed = block.timestamp - v.startTs;
        uint256 vested = elapsed >= v.duration ? v.amountWad : (v.amountWad * elapsed) / v.duration;
        return vested > v.withdrawnWad ? (vested - v.withdrawnWad) : 0;
    }

    // ---------------- Hooks Core ----------------
    function onDeposit(
        address user,
        uint256,
        /*addedAssetsWad*/
        uint256 newUserAssetsSnapshotWad
    )
        external
        override
        onlyCore
    {
        Streak storage s = streaks[user];

        // Se non attivo, aggiorno comunque il principal (per coerenza UI), ma non maturer├á bonus.
        if (s.startTs == 0 || s.principalWad == 0) {
            s.startTs = block.timestamp;
            s.lastAccrualTs = block.timestamp;
            s.principalWad = newUserAssetsSnapshotWad;
            emit StreakReset(user, block.timestamp);
        } else {
            // opzionale: qui potremmo "autoclaimare" il pending; preferiamo demandarlo al Core/utente
            // Aggiorno la base alla nuova fotografia
            s.principalWad = newUserAssetsSnapshotWad;
        }
    }

    function claimAndCreateVesting(address user, uint256 userAssetsSnapshotWad)
        external
        override
        onlyCore
        returns (uint256 claimed)
    {
        require(_active, "incentives-inactive"); // disattivato: non si pu├▓ creare nuova tranche

        Streak storage s = streaks[user];
        if (s.startTs == 0 || s.principalWad == 0) return 0;

        uint256 t1 = _daysFrom(s.startTs, s.lastAccrualTs);
        uint256 t2 = _daysFrom(s.startTs, block.timestamp);
        claimed = _bonusAmount(s.principalWad, t1, t2);
        require(claimed > 0, "no-bonus");

        // Checkpoint
        s.lastAccrualTs = block.timestamp;
        // Allineo la base alla fotografia passata dal Core (pps-consistent)
        s.principalWad = userAssetsSnapshotWad;

        // Crea vesting
        Vesting memory v;
        v.amountWad = claimed;
        v.startTs = block.timestamp;
        v.duration = _p.vestingDays * 1 days;
        v.withdrawnWad = 0;
        v.active = true;

        _vestings[user].push(v);
        uint256 idx = _vestings[user].length - 1;

        emit BonusClaimed(user, claimed, idx);
    }

    function withdrawVested(address user, uint256 idx, uint256 amountWad)
        external
        override
        onlyCore
        returns (uint256 paid)
    {
        Vesting storage v = _vestings[user][idx];
        require(v.active, "vesting-inactive");
        uint256 available = vestedAvailable(user, idx);
        require(amountWad <= available, "exceeds-vested");

        v.withdrawnWad += amountWad;
        paid = amountWad;

        emit BonusWithdrawn(user, idx, paid);
        // Il Core trasferir├á 'paid' all'utente (asset/shares) secondo la propria contabilit├á.
    }

    function onExit(address user)
        external
        override
        onlyCore
        returns (uint256 vestedToUser, uint256 slashedToTreasury)
    {
        // 1) Opzionale (fuori da qui): il Core pu├▓ aver chiamato prima claimAndCreateVesting() se vuole
        //    catturare il pending in una tranche. Qui gestiamo SOLO tranche esistenti.

        // 2) Slasha parte non vestita su tutte le tranche attive
        Vesting[] storage arr = _vestings[user];
        uint256 len = arr.length;
        for (uint256 i = 0; i < len; i++) {
            Vesting storage v = arr[i];
            if (!v.active) continue;

            // calcolo vested totale e residuo non vestito
            uint256 elapsed = block.timestamp > v.startTs ? (block.timestamp - v.startTs) : 0;
            uint256 totalVested =
                elapsed >= v.duration ? v.amountWad : (v.amountWad * elapsed) / v.duration;

            uint256 remaining = v.amountWad > v.withdrawnWad ? (v.amountWad - v.withdrawnWad) : 0;
            uint256 availableVestedNow =
                totalVested > v.withdrawnWad ? (totalVested - v.withdrawnWad) : 0;

            uint256 unvestedRemaining =
                remaining > availableVestedNow ? (remaining - availableVestedNow) : 0;

            if (availableVestedNow > 0) {
                vestedToUser += availableVestedNow;
                v.withdrawnWad += availableVestedNow; // marcare come ritirato (il Core pagher├á ora)
            }
            if (unvestedRemaining > 0) {
                slashedToTreasury += unvestedRemaining;
                emit UnvestedSlashed(user, i, unvestedRemaining);
            }

            // chiudo la tranche
            v.active = false;
        }

        // 3) Azzero la streak (uscita totale): il Core brucer├á le shares/trasferir├á asset
        Streak storage s = streaks[user];
        s.startTs = block.timestamp;
        s.lastAccrualTs = block.timestamp;
        s.principalWad = 0;

        emit StreakReset(user, block.timestamp);
    }
}
