// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Официальная библиотека Zama */
import {FHE, ebool, euint8, euint64, externalEuint8} from "@fhevm/solidity/lib/FHE.sol";
/* Конфиг Sepolia — даёт адреса KMS/Oracle/ACL */
import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/**
 * @title AnonymousBugReports
 * @notice Анонимные (псевдонимные на уровне EVM) репорты багов с приватной важностью.
 *         Пользователь шифрует важность (оценка 1..5), контракт агрегирует по проекту:
 *         хранит зашифрованные сумму оценок и количество репортов. Для фронта доступны
 *         bytes32-хэндлы, которые можно publicDecrypt / userDecrypt через Relayer SDK.
 *
 * Важно:
 *  - Никаких FHE-операций в view/pure.
 *  - ACL: FHE.allowThis(...) после каждого обновления, FHE.makePubliclyDecryptable(...)
 *    чтобы агрегаты были публично дешифруемы всем.
 *  - Делить среднее на контракте не пытаемся (деление на зашифрованный делитель нежелательно).
 *    Фронт сам найдёт average = sum / count после дешифровки.
 */
contract AnonymousBugReports is SepoliaConfig {
    /* ──────────── Ownable (минимальный) ──────────── */
    address public owner;
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero owner");
        owner = newOwner;
    }

    function version() external pure returns (string memory) {
        return "AnonymousBugReports/1.0.0-sepolia";
    }

    /* ──────────── Данные по проектам ──────────── */

    struct Agg {
        euint64 sum; // сумма оценок важности
        euint64 count; // количество валидных репортов
        bool exists;
    }

    mapping(uint256 => Agg) private _aggByProject;

    event ProjectInitialized(uint256 indexed projectId);
    event ReportSubmitted(
        uint256 indexed projectId,
        bytes32 indexed contentHash, // hash(payload) / IPFS CID hash / др.
        bytes32 severityHandle, // euint8
        bytes32 sumHandle, // euint64 (агрегированная сумма)
        bytes32 countHandle // euint64 (кол-во)
    );
    event AggregatesReset(uint256 indexed projectId);

    /* ──────────── Внутренняя инициализация ──────────── */
    function _ensureInit(uint256 projectId) private {
        if (!_aggByProject[projectId].exists) {
            euint64 z = FHE.asEuint64(0);
            // Разрешаем контракту переиспользовать созданные шифротексты
            FHE.allowThis(z);
            _aggByProject[projectId] = Agg({sum: z, count: z, exists: true});
            // Публичная дешифровка стартовых значений (0)
            FHE.makePubliclyDecryptable(_aggByProject[projectId].sum);
            FHE.makePubliclyDecryptable(_aggByProject[projectId].count);
            emit ProjectInitialized(projectId);
        }
    }

    /* ──────────── Основной метод: зашифрованный репорт ────────────
       @param projectId   Идентификатор проекта/продукта
       @param contentHash Хэш содержимого репорта (offchain payload / текст / вложения)
       @param severityExt Важность (1..5), externalEuint8 от Relayer SDK
       @param proof       ZK-доказательство корректности входа
    */
    function submitReport(
        uint256 projectId,
        bytes32 contentHash,
        externalEuint8 severityExt,
        bytes calldata proof
    ) external {
        require(projectId != 0, "projectId=0 reserved");
        require(contentHash != bytes32(0), "Empty contentHash");
        require(proof.length > 0, "Empty proof");

        _ensureInit(projectId);

        // 1) Десериализация и валидация диапазона 1..5 (приватно)
        euint8 sev = FHE.fromExternal(severityExt, proof);
        ebool ge1 = FHE.ge(sev, FHE.asEuint8(1));
        ebool le5 = FHE.le(sev, FHE.asEuint8(5));
        ebool isValid = FHE.and(ge1, le5);

        // Если вне диапазона — вклад = 0, инкремент счётчика = 0
        euint64 sev64 = FHE.asEuint64(sev);
        euint64 contrib = FHE.select(isValid, sev64, FHE.asEuint64(0));
        euint64 oneOrZero = FHE.select(isValid, FHE.asEuint64(1), FHE.asEuint64(0));

        // 2) Агрегирование: sum += contrib; count += oneOrZero
        Agg storage a = _aggByProject[projectId];
        a.sum = FHE.add(a.sum, contrib);
        a.count = FHE.add(a.count, oneOrZero);

        // 3) ACL: контракту — переиспользование; публикуем текущие хэндлы агрегатов
        FHE.allowThis(a.sum);
        FHE.allowThis(a.count);
        FHE.makePubliclyDecryptable(a.sum);
        FHE.makePubliclyDecryptable(a.count);

        emit ReportSubmitted(projectId, contentHash, FHE.toBytes32(sev), FHE.toBytes32(a.sum), FHE.toBytes32(a.count));
    }

    /* ──────────── Геттеры под фронт ──────────── */

    /// @notice Проверка существования проекта (инициализирован ли агрегатор)
    function projectExists(uint256 projectId) external view returns (bool) {
        return _aggByProject[projectId].exists;
    }

    /// @notice Текущие bytes32-хэндлы агрегатов (для publicDecrypt/userDecrypt)
    function getAggregateHandles(uint256 projectId) external view returns (bytes32 sumHandle, bytes32 countHandle) {
        Agg storage a = _aggByProject[projectId];
        require(a.exists, "Project not found");
        return (FHE.toBytes32(a.sum), FHE.toBytes32(a.count));
    }

    /* ──────────── Управление агрегатами ──────────── */

    /// @notice Сброс агрегатов проекта в 0 (новые хэндлы), только владелец.
    ///         Полезно начать заново после релиза, чтобы не смешивать разные версии.
    function resetAggregates(uint256 projectId) external onlyOwner {
        require(_aggByProject[projectId].exists, "Project not found");
        euint64 z = FHE.asEuint64(0);
        FHE.allowThis(z);
        _aggByProject[projectId].sum = z;
        _aggByProject[projectId].count = z;
        // Делаем новые нулевые хэндлы публично дешифруемыми
        FHE.makePubliclyDecryptable(_aggByProject[projectId].sum);
        FHE.makePubliclyDecryptable(_aggByProject[projectId].count);
        emit AggregatesReset(projectId);
    }

    /// @notice Выдать конкретному адресу право на дешифровку текущих агрегатов.
    ///         (Если агрегаты уже публичные — шаг не обязателен.)
    function shareAggregates(uint256 projectId, address viewer) external onlyOwner {
        require(viewer != address(0), "Zero viewer");
        Agg storage a = _aggByProject[projectId];
        require(a.exists, "Project not found");
        FHE.allow(a.sum, viewer);
        FHE.allow(a.count, viewer);
    }
}
