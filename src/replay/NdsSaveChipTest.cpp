#include "melonds/HeadlessSaveManager.h"

#include "NDSCart/CartRetail.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <initializer_list>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include <unistd.h>

namespace {

using melonDS::NDSCart::CartRetail;
using nds4mister::HeadlessSaveManager;
using namespace std::chrono_literals;

class TemporaryDirectory final {
public:
    TemporaryDirectory()
    {
        std::array<char, 64> name{};
        const std::string pattern = "/tmp/nds4mister-chip-save-test.XXXXXX";
        std::copy(pattern.begin(), pattern.end(), name.begin());
        char* created = mkdtemp(name.data());
        if (!created) throw std::runtime_error("mkdtemp failed");
        path_ = created;
    }

    ~TemporaryDirectory()
    {
        std::error_code ignored;
        std::filesystem::remove_all(path_, ignored);
    }

    const std::filesystem::path& path() const noexcept { return path_; }

private:
    std::filesystem::path path_;
};

[[noreturn]] void fail(const char* expression, int line,
    const std::string& detail = {})
{
    std::string message = "line " + std::to_string(line) + ": " + expression;
    if (!detail.empty()) message += " (" + detail + ")";
    throw std::runtime_error(message);
}

#define CHECK(expression) \
    do { if (!(expression)) fail(#expression, __LINE__); } while (false)
#define CHECK_DETAIL(expression, detail) \
    do { if (!(expression)) fail(#expression, __LINE__, (detail)); } while (false)

std::vector<std::uint8_t> readFile(const std::filesystem::path& path)
{
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) throw std::runtime_error("cannot open test output");
    const auto length = input.tellg();
    if (length < 0) throw std::runtime_error("cannot size test output");
    std::vector<std::uint8_t> result(static_cast<std::size_t>(length));
    input.seekg(0);
    if (!result.empty() && !input.read(
            reinterpret_cast<char*>(result.data()), length))
        throw std::runtime_error("cannot read test output");
    return result;
}

void writeFile(const std::filesystem::path& path,
    const std::vector<std::uint8_t>& data)
{
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    if (!output || (!data.empty() && !output.write(
            reinterpret_cast<const char*>(data.data()), data.size())))
        throw std::runtime_error("cannot write test fixture");
}

void transaction(CartRetail& cart, std::initializer_list<std::uint8_t> bytes)
{
    cart.SPISelect();
    for (const auto byte : bytes)
        cart.SPITransmitReceive(byte);
    cart.SPIRelease();
}

void writeEnable(CartRetail& cart)
{
    transaction(cart, {0x06});
}

void modify(CartRetail& cart, std::uint8_t command, std::uint32_t address,
    std::initializer_list<std::uint8_t> bytes)
{
    writeEnable(cart);
    cart.SPISelect();
    cart.SPITransmitReceive(command);
    cart.SPITransmitReceive(static_cast<std::uint8_t>(address >> 16));
    cart.SPITransmitReceive(static_cast<std::uint8_t>(address >> 8));
    cart.SPITransmitReceive(static_cast<std::uint8_t>(address));
    for (const auto byte : bytes)
        cart.SPITransmitReceive(byte);
    cart.SPIRelease();
}

void erase(CartRetail& cart, std::uint8_t command, std::uint32_t address)
{
    modify(cart, command, address, {});
}

void modifyEeprom(CartRetail& cart, std::uint32_t address,
    std::initializer_list<std::uint8_t> bytes)
{
    writeEnable(cart);
    cart.SPISelect();
    cart.SPITransmitReceive(0x02);
    cart.SPITransmitReceive(static_cast<std::uint8_t>(address >> 8));
    cart.SPITransmitReceive(static_cast<std::uint8_t>(address));
    for (const auto byte : bytes)
        cart.SPITransmitReceive(byte);
    cart.SPIRelease();
}

void expectRange(const std::uint8_t* save, std::uint32_t offset,
    std::uint32_t length, std::uint8_t expected)
{
    for (std::uint32_t index = 0; index < length; ++index)
        CHECK(save[offset + index] == expected);
}

void testFlashChipAndPersistence(const std::filesystem::path& root)
{
    constexpr std::uint32_t saveLength = 256u * 1024u;
    constexpr std::uint32_t pageBase = 0x1200;
    constexpr std::uint32_t sectorBase = 0x10000;
    const std::array<std::uint8_t, 8> identityBytes{{
        0x46, 0x4c, 0x41, 0x53, 0x48, 0x53, 0x50, 0x49,
    }};
    const auto identity = HeadlessSaveManager::contentId(
        identityBytes.data(), identityBytes.size());
    std::string error;
    auto manager = HeadlessSaveManager::create(
        root.string(), identity, error, 5ms, 25ms);
    CHECK_DETAIL(manager != nullptr, error);

    // CartCommon copies the complete extended DS/DSi header on construction.
    std::array<std::uint8_t, 4096> dummyRom{};
    melonDS::ROMListEntry parameters{};
    parameters.ROMSize = dummyRom.size();
    parameters.SaveMemType = 5;
    CartRetail cart(dummyRom.data(), dummyRom.size(), 0, false, parameters,
        nullptr, 0, manager->callback());
    cart.Reset();
    CHECK(cart.GetSaveMemoryLength() == saveLength);
    CHECK(cart.GetSaveMemory() != nullptr);
    CHECK_DETAIL(manager->initialize(cart.GetSaveMemory(), saveLength, 0,
        error), error);
    auto* const save = cart.GetSaveMemory();
    expectRange(save, 0, saveLength, 0xff);

    // Page Program preserves already-cleared bits and applies the transmitted
    // value.  The prior implementation wrote zero for every data byte.
    modify(cart, 0x02, pageBase + 0x34, {0xf0, 0x0f, 0xaa});
    CHECK(save[pageBase + 0x34] == 0xf0);
    CHECK(save[pageBase + 0x35] == 0x0f);
    CHECK(save[pageBase + 0x36] == 0xaa);
    modify(cart, 0x02, pageBase + 0x34, {0xcc, 0xf3, 0x55});
    CHECK(save[pageBase + 0x34] == 0xc0);
    CHECK(save[pageBase + 0x35] == 0x03);
    CHECK(save[pageBase + 0x36] == 0x00);

    // Both Page Program and Page Write wrap inside their original 256-byte
    // page rather than spilling into the next physical page.
    modify(cart, 0x02, pageBase + 0xfe, {0x11, 0x22, 0x33, 0x44});
    CHECK(save[pageBase + 0xfe] == 0x11);
    CHECK(save[pageBase + 0xff] == 0x22);
    CHECK(save[pageBase + 0x00] == 0x33);
    CHECK(save[pageBase + 0x01] == 0x44);
    CHECK(save[pageBase + 0x100] == 0xff);
    modify(cart, 0x0a, pageBase + 0xff, {0x81, 0x82, 0x83});
    CHECK(save[pageBase + 0xff] == 0x81);
    CHECK(save[pageBase + 0x00] == 0x82);
    CHECK(save[pageBase + 0x01] == 0x83);
    CHECK(save[pageBase + 0x34] == 0xc0);

    // Erase commands target the containing page/sector and restore erased
    // bytes to one.  The prior implementation filled these ranges with zero.
    modify(cart, 0x0a, pageBase - 1, {0x00, 0x00, 0x00});
    modify(cart, 0x0a, pageBase + 0x100, {0x00});
    erase(cart, 0xdb, pageBase + 0x5a);
    expectRange(save, pageBase, 0x100, 0xff);
    CHECK(save[pageBase - 1] == 0x00);
    CHECK(save[pageBase + 0x100] == 0x00);

    modify(cart, 0x0a, sectorBase - 1, {0x00, 0x00, 0x00});
    modify(cart, 0x0a, sectorBase + 0x10000, {0x00});
    erase(cart, 0xd8, sectorBase + 0x4321);
    expectRange(save, sectorBase, 0x10000, 0xff);
    CHECK(save[sectorBase - 1] == 0x00);
    CHECK(save[sectorBase + 0x10000] == 0x00);

    // Persist the exact chip image atomically, then simulate a complete
    // process restart and verify byte-for-byte reload compatibility.
    CHECK_DETAIL(manager->flush(error), error);
    const std::vector<std::uint8_t> expected(save, save + saveLength);
    CHECK(readFile(manager->savePathForTest()) == expected);
    CHECK_DETAIL(manager->shutdown(error), error);
    manager.reset();

    manager = HeadlessSaveManager::create(
        root.string(), identity, error, 5ms, 25ms);
    CHECK_DETAIL(manager != nullptr, error);
    std::unique_ptr<std::uint8_t[]> loaded;
    std::uint32_t loadedLength = 0;
    CHECK_DETAIL(manager->loadExisting(loaded, loadedLength, error), error);
    CHECK(loadedLength == saveLength);
    CHECK(std::equal(expected.begin(), expected.end(), loaded.get()));
    CHECK_DETAIL(manager->initialize(
        loaded.get(), loadedLength, loadedLength, error), error);
    CHECK_DETAIL(manager->shutdown(error), error);
}

void testEepromExistingSaveAndReset(const std::filesystem::path& root)
{
    constexpr std::uint32_t saveLength = 8u * 1024u;
    const std::array<std::uint8_t, 6> identityBytes{{
        0x45, 0x45, 0x50, 0x52, 0x4f, 0x4d,
    }};
    const auto identity = HeadlessSaveManager::contentId(
        identityBytes.data(), identityBytes.size());
    std::string error;
    auto manager = HeadlessSaveManager::create(
        root.string(), identity, error, 5ms, 25ms);
    CHECK_DETAIL(manager != nullptr, error);

    // Seed a pre-existing raw save.  Loading it must preserve every byte in
    // the cart, across a cart reset, subsequent byte/word writes, an atomic
    // flush, and another complete process-style reload.
    std::vector<std::uint8_t> expected(saveLength, 0xff);
    for (std::uint32_t index = 0; index < saveLength; index += 257)
        expected[index] = static_cast<std::uint8_t>(index >> 3);
    writeFile(manager->savePathForTest(), expected);

    std::unique_ptr<std::uint8_t[]> loaded;
    std::uint32_t loadedLength = 0;
    CHECK_DETAIL(manager->loadExisting(loaded, loadedLength, error), error);
    CHECK(loadedLength == saveLength);

    std::array<std::uint8_t, 4096> dummyRom{};
    melonDS::ROMListEntry parameters{};
    parameters.ROMSize = dummyRom.size();
    parameters.SaveMemType = 2;
    CartRetail cart(dummyRom.data(), dummyRom.size(), 0, false, parameters,
        std::move(loaded), loadedLength, manager->callback());
    CHECK(cart.GetSaveMemoryLength() == saveLength);
    CHECK(std::equal(expected.begin(), expected.end(), cart.GetSaveMemory()));
    CHECK_DETAIL(manager->initialize(cart.GetSaveMemory(), saveLength,
        loadedLength, error), error);

    cart.Reset();
    CHECK(std::equal(expected.begin(), expected.end(), cart.GetSaveMemory()));
    modifyEeprom(cart, 0x123, {0x12});
    expected[0x123] = 0x12;
    modifyEeprom(cart, 0x234, {0xde, 0xad, 0xbe, 0xef});
    expected[0x234] = 0xde;
    expected[0x235] = 0xad;
    expected[0x236] = 0xbe;
    expected[0x237] = 0xef;
    cart.Reset();
    CHECK(std::equal(expected.begin(), expected.end(), cart.GetSaveMemory()));

    CHECK_DETAIL(manager->flush(error), error);
    CHECK(readFile(manager->savePathForTest()) == expected);
    CHECK_DETAIL(manager->shutdown(error), error);
    manager.reset();

    manager = HeadlessSaveManager::create(
        root.string(), identity, error, 5ms, 25ms);
    CHECK_DETAIL(manager != nullptr, error);
    loadedLength = 0;
    CHECK_DETAIL(manager->loadExisting(loaded, loadedLength, error), error);
    CHECK(loadedLength == saveLength);
    CHECK(std::equal(expected.begin(), expected.end(), loaded.get()));
    CHECK_DETAIL(manager->initialize(
        loaded.get(), loadedLength, loadedLength, error), error);
    CHECK_DETAIL(manager->shutdown(error), error);
}

} // namespace

int main() try
{
    TemporaryDirectory temporary;
    testFlashChipAndPersistence(temporary.path());
    testEepromExistingSaveAndReset(temporary.path());
    std::cout << "NDS4MISTER_SAVE_CHIP_TEST_V1 status=pass\n";
    return 0;
} catch (const std::exception& error) {
    std::cerr << "NDS4MISTER_SAVE_CHIP_TEST_V1 status=fail error=\""
              << error.what() << "\"\n";
    return 1;
}
