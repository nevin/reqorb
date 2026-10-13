//! reqorb's own JSON file format.

use serde::{Deserialize, Serialize};

use super::util::pretty;
use crate::{Collection, Environment};

/// Version written to the `reqorb` field of native files.
pub(crate) const NATIVE_VERSION: u32 = 1;

/// reqorb's own file format: any number of collections and environments.
#[derive(Debug, Default, Serialize, Deserialize)]
pub(crate) struct NativeFile {
    pub reqorb: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub collections: Vec<Collection>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub environments: Vec<Environment>,
}

/// Bundles collections and environments into one reqorb file.
pub fn export_native(collections: &[Collection], environments: &[Environment]) -> String {
    pretty(&NativeFile {
        reqorb: NATIVE_VERSION,
        // Where a collection is kept on this machine is nobody else's concern.
        collections: collections
            .iter()
            .map(|collection| Collection {
                link: None,
                ..collection.clone()
            })
            .collect(),
        environments: environments.to_vec(),
    })
}
