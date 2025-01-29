module maniac_nfts::maniac_attribute;

use std::string;
use sui::display;
use sui::package;
use sui::random::{Self, Random};
use sui::table::{Self, Table};
use sui::url::{Self, Url};

// Errors
const EInvalidArrayLength: u64 = 0;
const ENotAdmin: u64 = 1;

public struct Admin has store {
    admin_address: address,
}

public struct MintingControl has key, store {
    id: UID,
    admin: Admin,
}

public struct MANIAC_ATTRIBUTE has drop {}

public struct ManiacAttributeNft has key, store {
    id: UID,
    name: string::String,
    image_url: Url,
    field_type: string::String,
    field_value: string::String,
}

public fun field_type(nft: &ManiacAttributeNft): &string::String {
    &nft.field_type
}

public fun field_value(nft: &ManiacAttributeNft): &string::String {
    &nft.field_value
}

fun is_admin(control: &MintingControl, caller: address): bool {
    control.admin.admin_address == caller
}

public struct AttributeMappingItem has store {
    probabilities: vector<u64>,
    id_to_value: Table<u64, vector<u8>>,
}

public struct AttributeMapping has key, store {
    id: UID,
    background: AttributeMappingItem,
    body: AttributeMappingItem,
    hat: AttributeMappingItem,
    beard: AttributeMappingItem,
    eyes: AttributeMappingItem,
}

fun init(otw: MANIAC_ATTRIBUTE, ctx: &mut TxContext) {
    let keys = vector[
        b"name".to_string(),
        b"image_url".to_string(),
        b"project_url".to_string(),
        b"creator".to_string(),
    ];

    let values = vector[
        b"{name}".to_string(),
        b"{image_url}".to_string(),
        b"https://coinfever.app".to_string(),
        b"CoinFever".to_string(),
    ];

    // Claim the `Publisher` for the package!
    let publisher = package::claim(otw, ctx);

    // Get a new `Display` object for the `Hero` type.
    let mut display = display::new_with_fields<ManiacAttributeNft>(
        &publisher,
        keys,
        values,
        ctx,
    );

    // Commit first version of `Display` to apply changes.
    display.update_version();

    transfer::public_transfer(publisher, ctx.sender());
    transfer::public_transfer(display, ctx.sender());

    let mintingControl = MintingControl {
        id: object::new(ctx),
        admin: Admin { admin_address: ctx.sender() },
    };

    transfer::share_object(mintingControl);

    let attributeMapping = AttributeMapping {
        id: object::new(ctx),
        background: AttributeMappingItem {
            probabilities: vector[],
            id_to_value: table::new(ctx),
        },
        body: AttributeMappingItem {
            probabilities: vector[],
            id_to_value: table::new(ctx),
        },
        hat: AttributeMappingItem {
            probabilities: vector[],
            id_to_value: table::new(ctx),
        },
        beard: AttributeMappingItem {
            probabilities: vector[],
            id_to_value: table::new(ctx),
        },
        eyes: AttributeMappingItem {
            probabilities: vector[],
            id_to_value: table::new(ctx),
        },
    };

    transfer::share_object(attributeMapping);
}

public fun add_attribute(
    control: &mut MintingControl,
    mapping: &mut AttributeMapping,
    mut field_type_arr: vector<vector<u8>>,
    mut field_value_arr: vector<vector<u8>>,
    mut probability_arr: vector<u64>,
    ctx: &mut TxContext,
) {
    let caller = ctx.sender();
    assert!(is_admin(control, caller), ENotAdmin);

    assert!(
        field_type_arr.length() == field_value_arr.length() && field_value_arr.length() == probability_arr.length(),
        EInvalidArrayLength,
    );

    while (!field_type_arr.is_empty()) {
        let field_type = field_type_arr.pop_back();
        let field_value = field_value_arr.pop_back();
        let probability = probability_arr.pop_back();

        let selectedMapping = match (field_type) {
            b"background" => &mut mapping.background,
            b"body" => &mut mapping.body,
            b"hat" => &mut mapping.hat,
            b"beard" => &mut mapping.beard,
            b"eyes" => &mut mapping.eyes,
            _ => &mut mapping.background,
        };

        vector::push_back(&mut selectedMapping.probabilities, probability);
        table::add(
            &mut selectedMapping.id_to_value,
            selectedMapping.probabilities.length() - 1,
            field_value,
        );
    };

    field_type_arr.destroy_empty();
    field_value_arr.destroy_empty();
    probability_arr.destroy_empty();
}

public fun get_attribute(
    mapping: &AttributeMapping,
    field_type: vector<u8>,
    field_id: u64,
): vector<u8> {
    match (field_type) {
        b"background" => *table::borrow(&mapping.background.id_to_value, field_id),
        b"body" => *table::borrow(&mapping.body.id_to_value, field_id),
        b"hat" => *table::borrow(&mapping.hat.id_to_value, field_id),
        b"beard" => *table::borrow(&mapping.beard.id_to_value, field_id),
        b"eyes" => *table::borrow(&mapping.eyes.id_to_value, field_id),
        _ => b"None",
    }
}

fun get_random_number(probabilities: &vector<u64>, random: &Random, ctx: &mut TxContext): u64 {
    // Calculate the total sum of the probabilities
    let mut total = 0;
    let mut i = 0;
    while (i < vector::length(probabilities)) {
        total = total + *vector::borrow(probabilities, i);
        i = i + 1;
    };

    let mut generator = random::new_generator(random, ctx);
    let rand = random::generate_u64_in_range(&mut generator, 0, total - 1);

    // Find the corresponding index based on cumulative probabilities
    let mut cumulative = 0;
    let mut index = 0;
    while (index < vector::length(probabilities)) {
        cumulative = cumulative + *vector::borrow(probabilities, index);
        if (rand < cumulative) {
            return index
        };
        index = index + 1;
    };

    // Default return (should not happen if probabilities are valid)
    0
}

fun get_random_attribute(
    mapping: &AttributeMapping,
    field_type: vector<u8>,
    random: &Random,
    ctx: &mut TxContext,
): vector<u8> {
    let selectedMapping = match (field_type) {
        b"background" => &mapping.background,
        b"body" => &mapping.body,
        b"hat" => &mapping.hat,
        b"beard" => &mapping.beard,
        b"eyes" => &mapping.eyes,
        _ => &mapping.background,
    };

    let random_attribute_id = get_random_number(&selectedMapping.probabilities, random, ctx);

    get_attribute(mapping, field_type, random_attribute_id)
}

fun create_attribute(
    field_type: vector<u8>,
    field_value: vector<u8>,
    ctx: &mut TxContext,
): ManiacAttributeNft {
    let mut fullName = field_value;
    fullName.append(b" Attribute");

    let mut imageUrl = b"https://base-metadata-api-testnet.vercel.app/layers/";
    imageUrl.append(field_type);
    imageUrl.append(b"/");
    imageUrl.append(field_value);
    imageUrl.append(b".png");

    ManiacAttributeNft {
        id: object::new(ctx),
        name: string::utf8(fullName),
        image_url: url::new_unsafe_from_bytes(imageUrl),
        field_type: string::utf8(field_type),
        field_value: string::utf8(field_value),
    }
}

public(package) fun create_random_attribute(
    mapping: &AttributeMapping,
    field_type: vector<u8>,
    random: &Random,
    ctx: &mut TxContext,
): ManiacAttributeNft {
    let random_attribute = get_random_attribute(mapping, field_type, random, ctx);

    create_attribute(field_type, random_attribute, ctx)
}
