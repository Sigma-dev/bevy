// GPU mesh uniform building.
//
// This is a compute shader that expands each `MeshInputUniform` out to a full
// `MeshUniform` for each view before rendering. (Thus `MeshInputUniform`
// and `MeshUniform` are in a 1:N relationship.) It runs in parallel for all
// meshes for all views. As part of this process, the shader gathers each
// mesh's transform on the previous frame and writes it into the `MeshUniform`
// so that TAA works.

#import bevy_pbr::mesh_types::{Mesh, MESH_FLAGS_NO_FRUSTUM_CULLING_BIT}
#import bevy_pbr::mesh_preprocess_types::{MeshInput, IndirectParametersMetadata}
#import bevy_render::maths
#import bevy_render::view::View

// Information about each mesh instance needed to cull it on GPU.
//
// At the moment, this just consists of its axis-aligned bounding box (AABB).
struct MeshCullingData {
    // The 3D center of the AABB in model space, padded with an extra unused
    // float value.
    aabb_center: vec4<f32>,
    // The 3D extents of the AABB in model space, divided by two, padded with
    // an extra unused float value.
    aabb_half_extents: vec4<f32>,
}

// One invocation of this compute shader: i.e. one mesh instance in a view.
struct PreprocessWorkItem {
    // The index of the `MeshInput` in the `current_input` buffer that we read
    // from.
    input_index: u32,
    // The index of the `Mesh` in `output` that we write to.
    output_index: u32,
    // The index of the `IndirectParameters` in `indirect_parameters` that we
    // write to.
    indirect_parameters_index: u32,
}

// The current frame's `MeshInput`.
@group(0) @binding(0) var<storage> current_input: array<MeshInput>;
// The `MeshInput` values from the previous frame.
@group(0) @binding(1) var<storage> previous_input: array<MeshInput>;
// Indices into the `MeshInput` buffer.
//
// There may be many indices that map to the same `MeshInput`.
@group(0) @binding(2) var<storage> work_items: array<PreprocessWorkItem>;
// The output array of `Mesh`es.
@group(0) @binding(3) var<storage, read_write> output: array<Mesh>;

#ifdef INDIRECT
// The array of indirect parameters for drawcalls.
@group(0) @binding(4) var<storage, read_write> indirect_parameters_metadata:
    array<IndirectParametersMetadata>;
#endif

#ifdef FRUSTUM_CULLING
// Data needed to cull the meshes.
//
// At the moment, this consists only of AABBs.
@group(0) @binding(5) var<storage> mesh_culling_data: array<MeshCullingData>;

// The view data, including the view matrix.
@group(0) @binding(6) var<uniform> view: View;

// Returns true if the view frustum intersects an oriented bounding box (OBB).
//
// `aabb_center.w` should be 1.0.
fn view_frustum_intersects_obb(
    world_from_local: mat4x4<f32>,
    aabb_center: vec4<f32>,
    aabb_half_extents: vec3<f32>,
) -> bool {

    for (var i = 0; i < 5; i += 1) {
        // Calculate relative radius of the sphere associated with this plane.
        let plane_normal = view.frustum[i];
        let relative_radius = dot(
            abs(
                vec3(
                    dot(plane_normal, world_from_local[0]),
                    dot(plane_normal, world_from_local[1]),
                    dot(plane_normal, world_from_local[2]),
                )
            ),
            aabb_half_extents
        );

        // Check the frustum plane.
        if (!maths::sphere_intersects_plane_half_space(
                plane_normal, aabb_center, relative_radius)) {
            return false;
        }
    }

    return true;
}
#endif

@compute
@workgroup_size(64)
fn main(@builtin(global_invocation_id) global_invocation_id: vec3<u32>) {
    // Figure out our instance index. If this thread doesn't correspond to any
    // index, bail.
    let instance_index = global_invocation_id.x;
    if (instance_index >= arrayLength(&work_items)) {
        return;
    }

    // Unpack the work item.
    let input_index = work_items[instance_index].input_index;
    let output_index = work_items[instance_index].output_index;
    let indirect_parameters_index = work_items[instance_index].indirect_parameters_index;

    // Unpack the input matrix.
    let world_from_local_affine_transpose = current_input[input_index].world_from_local;
    let world_from_local = maths::affine3_to_square(world_from_local_affine_transpose);

    // Cull if necessary.
#ifdef FRUSTUM_CULLING
    if ((current_input[input_index].flags & MESH_FLAGS_NO_FRUSTUM_CULLING_BIT) == 0u) {
        let aabb_center = mesh_culling_data[input_index].aabb_center.xyz;
        let aabb_half_extents = mesh_culling_data[input_index].aabb_half_extents.xyz;

        // Do an OBB-based frustum cull.
        let model_center = world_from_local * vec4(aabb_center, 1.0);
        if (!view_frustum_intersects_obb(world_from_local, model_center, aabb_half_extents)) {
            return;
        }
    }
#endif

    // Calculate inverse transpose.
    let local_from_world_transpose = transpose(maths::inverse_affine3(transpose(
        world_from_local_affine_transpose)));

    // Pack inverse transpose.
    let local_from_world_transpose_a = mat2x4<f32>(
        vec4<f32>(local_from_world_transpose[0].xyz, local_from_world_transpose[1].x),
        vec4<f32>(local_from_world_transpose[1].yz, local_from_world_transpose[2].xy));
    let local_from_world_transpose_b = local_from_world_transpose[2].z;

    // Look up the previous model matrix.
    let previous_input_index = current_input[input_index].previous_input_index;
    var previous_world_from_local: mat3x4<f32>;
    if (previous_input_index == 0xffffffff) {
        previous_world_from_local = world_from_local_affine_transpose;
    } else {
        previous_world_from_local = previous_input[previous_input_index].world_from_local;
    }

    // Figure out the output index. In indirect mode, this involves bumping the
    // instance index in the indirect parameters metadata, which
    // `build_indirect_params.wgsl` will use to generate the actual indirect
    // parameters. Otherwise, this index was directly supplied to us.
#ifdef INDIRECT
    let batch_output_index =
        atomicAdd(&indirect_parameters_metadata[indirect_parameters_index].instance_count, 1u);
    let mesh_output_index =
        indirect_parameters_metadata[indirect_parameters_index].base_output_index +
        batch_output_index;
#else   // INDIRECT
    let mesh_output_index = output_index;
#endif  // INDIRECT

    // Write the output.
    output[mesh_output_index].world_from_local = world_from_local_affine_transpose;
    output[mesh_output_index].previous_world_from_local = previous_world_from_local;
    output[mesh_output_index].local_from_world_transpose_a = local_from_world_transpose_a;
    output[mesh_output_index].local_from_world_transpose_b = local_from_world_transpose_b;
    output[mesh_output_index].flags = current_input[input_index].flags;
    output[mesh_output_index].lightmap_uv_rect = current_input[input_index].lightmap_uv_rect;
    output[mesh_output_index].first_vertex_index = current_input[input_index].first_vertex_index;
    output[mesh_output_index].current_skin_index = current_input[input_index].current_skin_index;
    output[mesh_output_index].previous_skin_index = current_input[input_index].previous_skin_index;
    output[mesh_output_index].material_and_lightmap_bind_group_slot =
        current_input[input_index].material_and_lightmap_bind_group_slot;
}
