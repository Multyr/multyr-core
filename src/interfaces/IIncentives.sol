// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Interfaccia del modulo Incentivi (Loyalty Boost).
/// Tutti gli importi esposti/attesi sono in WAD (1e18) salvo diversa nota.
interface IIncentives {
    // -------- Params --------
    struct Params {
        uint256 cliffDays; // Tc (es. 30)
        uint256 fullDays; // Tf (es. 180)
        uint256 bmaxWad; // Bmax in 1e18 (es. 0.03e18)
        uint256 vestingDays; // durata vesting post-claim (es. 180)
    }

    // -------- Admin / Setup --------
    function setCore(address core_) external;
    function setTreasury(address treasury_) external;
    function setParams(Params calldata p) external;
    function setActive(bool active_) external;

    // -------- Views --------
    function isActive() external view returns (bool);
    function getParams() external view returns (Params memory);
    function core() external view returns (address);
    function treasury() external view returns (address);

    // Dati per UI
    function currentTDays(address user) external view returns (uint256);
    function pendingBonus(address user) external view returns (uint256);
    function vestingsCount(address user) external view returns (uint256);
    function vestedAvailable(address user, uint256 idx) external view returns (uint256);

    // -------- Hooks chiamati dal Core --------
    /// @dev Deve essere chiamato dal Core dopo che il Core ha aggiornato le quote/saldi utente.
    /// @param user L'utente
    /// @param addedAssetsWad Nuovi asset (in WAD) depositati in questa operazione (informativo)
    /// @param newUserAssetsSnapshotWad Snapshot degli asset totali utente (in WAD) dopo il deposito
    function onDeposit(address user, uint256 addedAssetsWad, uint256 newUserAssetsSnapshotWad)
        external;

    /// @dev Claim del bonus maturato → crea una tranche di vesting.
    /// @param user L'utente
    /// @param userAssetsSnapshotWad Snapshot coerente (WAD) della base di accrual al momento del claim
    /// @return claimed Importo di bonus accantonato nella nuova tranche (WAD)
    function claimAndCreateVesting(address user, uint256 userAssetsSnapshotWad)
        external
        returns (uint256 claimed);

    /// @dev Prelievo di bonus già vestito da una tranche.
    /// @return paid Importo effettivamente prelevato (WAD)
    function withdrawVested(address user, uint256 idx, uint256 amountWad)
        external
        returns (uint256 paid);

    /// @dev Chiamata su uscita totale: slasha la parte non vestita di tutte le tranche attive.
    /// @return vestedToUser Somma vestita da pagare all'utente (WAD)
    /// @return slashedToTreasury Somma non vestita da inviare alla Treasury (WAD)
    function onExit(address user) external returns (uint256 vestedToUser, uint256 slashedToTreasury);
}
