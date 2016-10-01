# This file is a part of JuliaFEM.
# License is MIT: see https://github.com/JuliaFEM/JuliaFEM.jl/blob/master/LICENSE.md

"""
Frictionless 2d small sliding contact without forwarddiff.

true/false flags: finite_sliding, friction, use_forwarddiff
"""
function assemble!(problem::Problem{Contact}, time::Float64,
                   ::Type{Val{1}}, ::Type{Val{false}},
                   ::Type{Val{false}}, ::Type{Val{false}}; debug=false)

    props = problem.properties
    field_dim = get_unknown_field_dimension(problem)
    field_name = get_parent_field_name(problem)
    slave_elements = get_slave_elements(problem)

    # 1. calculate nodal normals and tangents for slave element nodes j ∈ S
    normals, tangents = calculate_normals(slave_elements, time, Val{1};
                        rotate_normals=props.rotate_normals)
    update!(slave_elements, "normal", time => normals)
    update!(slave_elements, "tangent", time => tangents)

    Rn = 0.0

    # 2. loop all slave elements
    for slave_element in slave_elements

        nsl = length(slave_element)
        X1 = slave_element("geometry", time)
        u1 = slave_element("displacement", time)
        la1 = slave_element("reaction force", time)
        n1 = slave_element("normal", time)
        t1 = slave_element("tangent", time)
        x1 = X1 + u1
        Q1_ = [n1[1] t1[1]]
        Q2_ = [n1[2] t1[2]]
        Z = zeros(2, 2)
        Q2 = [Q1_ Z; Z Q2_]
        contact_area = 0.0
        contact_error = 0.0

        if "element area" in props.store_fields
            element_area = 0.0
            for ip in get_integration_points(slave_element)
                detJ = slave_element(ip, time, Val{:detJ})
                w = ip.weight*detJ
                element_area += w
            end
            update!(slave_element, "element area", time => element_area)
        end

        # 3. loop all master elements
        for master_element in slave_element("master elements", time)

            nm = length(master_element)
            X2 = master_element("geometry", time)
            u2 = master_element("displacement", time)
            x2 = X2 + u2

            if norm(mean(X1) - X2[1]) / norm(X1[2] - X1[1]) > props.distval
                continue
            end

            if norm(mean(X1) - X2[2]) / norm(X1[2] - X1[1]) > props.distval
                continue
            end
            
            # 3.1 calculate segmentation
            xi1a = project_from_master_to_slave(slave_element, X2[1], time)
            xi1b = project_from_master_to_slave(slave_element, X2[2], time)
            xi1 = clamp([xi1a; xi1b], -1.0, 1.0)
            l = 1/2*abs(xi1[2]-xi1[1])
            isapprox(l, 0.0) && continue # no contribution in this master element

            # 3.2. bi-orthogonal basis
            De = zeros(nsl, nsl)
            Me = zeros(nsl, nsl)
            Ae = zeros(nsl, nsl)
            if props.dual_basis
                for ip in get_integration_points(slave_element, 3)
                    detJ = slave_element(ip, time, Val{:detJ})
                    w = ip.weight*detJ*l
                    xi = ip.coords[1]
                    xi_s = dot([1/2*(1-xi); 1/2*(1+xi)], xi1)
                    N1 = vec(get_basis(slave_element, xi_s, time))
                    De += w*diagm(N1)
                    Me += w*N1*N1'
                end
                Ae = De*inv(Me)
            else
                Ae = eye(nsl)
            end
            
            # 3.3. loop integration points of one integration segment and calculate
            # local mortar matrices
            fill!(De, 0.0)
            fill!(Me, 0.0)
            Ne = zeros(nsl, 2*nsl)
            Te = zeros(nsl, 2*nsl)
            He = zeros(nsl, 2*nsl)
            ce = zeros(nsl)
            ge = zeros(nsl)
            for ip in get_integration_points(slave_element, 3)
                detJ = slave_element(ip, time, Val{:detJ})
                w = ip.weight*detJ*l
                xi = ip.coords[1]
                xi_s = dot([1/2*(1-xi); 1/2*(1+xi)], xi1)
                N1 = vec(get_basis(slave_element, xi_s, time))
                Phi = Ae*N1

                # project gauss point from slave element to master element in direction n_s
                X_s = N1*X1 # coordinate in gauss point
                n_s = N1*n1 # normal direction in gauss point
                t_s = N1*t1 # tangent condition in gauss point
                n_s /= norm(n_s)
                t_s /= norm(t_s)
                xi_m = project_from_slave_to_master(master_element, X_s, n_s, time)
                N2 = vec(get_basis(master_element, xi_m, time))
                X_m = N2*X2 

                u_s = N1*u1
                u_m = N2*u2
                x_s = X_s + u_s
                x_m = X_m + u_m
                la_s = Phi*la1

                # virtual work
                De += w*Phi*N1'
                Me += w*Phi*N2'

                # contact constraints
                Ne += w*reshape(kron(N1, n_s, Phi), 2, 4)
                Te += w*reshape(kron(N2, n_s, Phi), 2, 4)
                He += w*reshape(kron(N1, t_s, Phi), 2, 4)
                ge += w*Phi*dot(n_s, x_m-x_s)
                ce += w*N1*dot(n_s, -la_s)
                Rn += w*dot(n_s, -la_s)

                contact_area += w
                contact_error += 1/2*w*dot(n_s, x_s-x_m)^2
            end

            sdofs = get_gdofs(problem, slave_element)
            mdofs = get_gdofs(problem, master_element)

            # add contribution to contact virtual work
            for i=1:field_dim
                lsdofs = sdofs[i:field_dim:end]
                lmdofs = mdofs[i:field_dim:end]
                add!(problem.assembly.C1, lsdofs, lsdofs, De)
                add!(problem.assembly.C1, lsdofs, lmdofs, -Me)
            end

            # add contribution to contact constraints
            add!(problem.assembly.C2, sdofs[1:field_dim:end], sdofs, Ne)
            add!(problem.assembly.C2, sdofs[1:field_dim:end], mdofs, -Te)
            add!(problem.assembly.D, sdofs[2:field_dim:end], sdofs, He)
            add!(problem.assembly.g, sdofs[1:field_dim:end], ge)
            add!(problem.assembly.c, sdofs[1:field_dim:end], ce)

        end # master elements done

        if "contact area" in props.store_fields
            update!(slave_element, "contact area", time => contact_area)
        end

        if "contact error" in props.store_fields
            update!(slave_element, "contact error", time => contact_error)
        end

    end # slave elements done, contact virtual work ready

    S = sort(collect(keys(normals))) # slave element nodes
    weighted_gap = Dict{Int64, Vector{Float64}}()
    contact_pressure = Dict{Int64, Vector{Float64}}()
    complementarity_condition = Dict{Int64, Vector{Float64}}()
    is_active = Dict{Int64, Int}()
    is_inactive = Dict{Int64, Int}()
    is_slip = Dict{Int64, Int}()
    is_stick = Dict{Int64, Int}()

    la = problem.assembly.la
    ndofs = length(la)
#   info("contact ndofs: $ndofs")
#   info("Rn = $Rn")

    C1 = sparse(problem.assembly.C1, ndofs, ndofs)
    C2 = sparse(problem.assembly.C2, ndofs, ndofs)
    D = sparse(problem.assembly.D, ndofs, ndofs)
    g = full(problem.assembly.g, ndofs, 1)
    c = full(problem.assembly.c, ndofs, 1)

    # active / inactive node detection
    for j in S
        dofs = [2*(j-1)+1, 2*(j-1)+2]
        weighted_gap[j] = g[dofs]

        if length(la) != 0
            p = dot(normals[j], la[dofs])
            t = dot(tangents[j], la[dofs])
            contact_pressure[j] = [p, t]
        else
            contact_pressure[j] = [0.0, 0.0]
        end

#       contact_pressure[j] = c[dofs]
        complementarity_condition[j] = contact_pressure[j] - weighted_gap[j]
        if complementarity_condition[j][1] < 0
            is_inactive[j] = 1
            is_active[j] = 0
            is_slip[j] = 0
            is_stick[j] = 0
        else
            is_inactive[j] = 0
            is_active[j] = 1
            is_slip[j] = 1
            is_stick[j] = 0
#           _c1 = complementarity_condition[j][1]
#           _c2 = c[dofs]
#           _c3 = contact_pressure[j][1]
#           _c4 = g[dofs]
#           info("active $j: c1 = $_c1, c2 = $_c2, c3 = $_c3, c4 = $_c4")
        end
    end

    if "weighted gap" in props.store_fields
        update!(slave_elements, "weighted gap", time => weighted_gap)
    end
    if "contact pressure" in props.store_fields
        update!(slave_elements, "contact pressure", time => contact_pressure)
    end
    if "complementarity condition" in props.store_fields
        update!(slave_elements, "complementarity condition", time => complementarity_condition)
    end
    if "active nodes" in props.store_fields
        update!(slave_elements, "active nodes", time => is_active)
    end
    if "inactive nodes" in props.store_fields
        update!(slave_elements, "inactive nodes", time => is_inactive)
    end
    if "stick nodes" in props.store_fields
        update!(slave_elements, "stick nodes", time => is_stick)
    end
    if "slip nodes" in props.store_fields
        update!(slave_elements, "slip nodes", time => is_slip)
    end

#   info("# | active | inactive | stick | slip | gap | pres | comp")
#   for j in S
#       str1 = "$j | $(is_active[j]) | $(is_inactive[j]) | $(is_stick[j]) | $(is_slip[j]) | "
#       str2 = "$(round(weighted_gap[j], 3)) | $(round(contact_pressure[j], 3)) | $(round(complementarity_condition[j], 3))"
#       info(str1 * str2)
#   end

    # solve variational inequality
    

    # constitutive modelling in tangent direction, frictionless contact
    #=
    for j in S
        dofs = [2*(j-1)+1, 2*(j-1)+2]
        if (is_active[j] == 1) && (is_slip[j] == 1)
            info("$j is in active/slip, removing tangential constraint $(dofs[2])")
            C2[dofs[2],:] = 0.0
            g[dofs[2]] = 0.0
            D[dofs[2], dofs] = tangents[j]
        end
    end
    =#

    # remove inactive nodes from assembly
    for j in S
        dofs = [2*(j-1)+1, 2*(j-1)+2]
        if is_inactive[j] == 1
#           info("$j is inactive, removing dofs $dofs")
            C1[dofs,:] = 0.0
            C2[dofs,:] = 0.0
            D[dofs,:] = 0.0
            g[dofs,:] = 0.0
        end
    end

    problem.assembly.C1 = C1
    problem.assembly.C2 = C2
    problem.assembly.D = D
    problem.assembly.g = g

end


"""
Frictionless 2d small sliding contact without forwarddiff.

true/false flags: finite_sliding, friction, use_forwarddiff
"""
function _assemble!(problem::Problem{Contact}, time::Float64,
                   ::Type{Val{1}}, ::Type{Val{false}},
                   ::Type{Val{false}}, ::Type{Val{false}}; debug=false)

    props = problem.properties
    field_dim = get_unknown_field_dimension(problem)
    field_name = get_parent_field_name(problem)
    slave_elements = get_slave_elements(problem)

    # 1. calculate nodal normals and tangents for slave element nodes j ∈ S
    normals, tangents = calculate_normals(slave_elements, time, Val{1};
                        rotate_normals=props.rotate_normals)
    update!(slave_elements, "normal", time => normals)
    update!(slave_elements, "tangent", time => tangents)

    Rn = 0.0

    # 2. loop all slave elements
    for slave_element in slave_elements

        nsl = length(slave_element)
        X1 = slave_element("geometry", time)
        u1 = slave_element("displacement", time)
        la1 = slave_element("reaction force", time)
        n1 = slave_element("normal", time)
        t1 = slave_element("tangent", time)
        x1 = X1 + u1
        Q1_ = [n1[1] t1[1]]
        Q2_ = [n1[2] t1[2]]
        Z = zeros(2, 2)
        Q2 = [Q1_ Z; Z Q2_]
        contact_area = 0.0
        contact_error = 0.0

        if "element area" in props.store_fields
            element_area = 0.0
            for ip in get_integration_points(slave_element)
                detJ = slave_element(ip, time, Val{:detJ})
                w = ip.weight*detJ
                element_area += w
            end
            update!(slave_element, "element area", time => element_area)
        end

        # 3. loop all master elements
        for master_element in slave_element("master elements", time)

            nm = length(master_element)
            X2 = master_element("geometry", time)
            u2 = master_element("displacement", time)
            x2 = X2 + u2

            if norm(mean(X1) - X2[1]) / norm(X1[2] - X1[1]) > props.distval
                continue
            end

            if norm(mean(X1) - X2[2]) / norm(X1[2] - X1[1]) > props.distval
                continue
            end
            
            # 3.1 calculate segmentation
            xi1a = project_from_master_to_slave(slave_element, X2[1], time)
            xi1b = project_from_master_to_slave(slave_element, X2[2], time)
            xi1 = clamp([xi1a; xi1b], -1.0, 1.0)
            l = 1/2*abs(xi1[2]-xi1[1])
            isapprox(l, 0.0) && continue # no contribution in this master element

            # 3.2. bi-orthogonal basis
            De = zeros(nsl, nsl)
            Me = zeros(nsl, nsl)
            Ae = zeros(nsl, nsl)
            if props.dual_basis
                for ip in get_integration_points(slave_element, 3)
                    detJ = slave_element(ip, time, Val{:detJ})
                    w = ip.weight*detJ*l
                    xi = ip.coords[1]
                    xi_s = dot([1/2*(1-xi); 1/2*(1+xi)], xi1)
                    N1 = vec(get_basis(slave_element, xi_s, time))
                    De += w*diagm(N1)
                    Me += w*N1*N1'
                end
                Ae = De*inv(Me)
            else
                Ae = eye(nsl)
            end
            
            # 3.3. loop integration points of one integration segment and calculate
            # local mortar matrices
            fill!(De, 0.0)
            fill!(Me, 0.0)
            ge = zeros(field_dim*nsl)
            for ip in get_integration_points(slave_element, 3)
                detJ = slave_element(ip, time, Val{:detJ})
                w = ip.weight*detJ*l
                xi = ip.coords[1]
                xi_s = dot([1/2*(1-xi); 1/2*(1+xi)], xi1)
                N1 = vec(get_basis(slave_element, xi_s, time))
                Phi = Ae*N1

                # project gauss point from slave element to master element in direction n_s
                X_s = N1*X1 # coordinate in gauss point
                n_s = N1*n1 # normal direction in gauss point
                t_s = N1*t1 # tangent condition in gauss point
                n_s /= norm(n_s)
                t_s /= norm(t_s)
                xi_m = project_from_slave_to_master(master_element, X_s, n_s, time)
                N2 = vec(get_basis(master_element, xi_m, time))
                X_m = N2*X2 

                u_s = N1*u1
                u_m = N2*u2
                x_s = X_s + u_s
                x_m = X_m + u_m
                la_s = Phi*la1
                ge += w*vec((x_m-x_s)*Phi')

                # virtual work
                De += w*Phi*N1'
                Me += w*Phi*N2'

                contact_area += w
                contact_error += 1/2*w*dot(n_s, x_s-x_m)^2
            end

            sdofs = get_gdofs(problem, slave_element)
            mdofs = get_gdofs(problem, master_element)

            # add contribution to contact virtual work
            D2 = zeros(field_dim*nsl, field_dim*nsl)
            M2 = zeros(field_dim*nsl, field_dim*nsl)
            for i=1:field_dim
                D2[i:field_dim:end, i:field_dim:end] += De
                M2[i:field_dim:end, i:field_dim:end] += Me
            end

            add!(problem.assembly.C1, sdofs, sdofs, D2)
            add!(problem.assembly.C1, sdofs, mdofs, -M2)
            add!(problem.assembly.C2, sdofs, sdofs, Q2'*D2)
            add!(problem.assembly.C2, sdofs, mdofs, -Q2'*M2)
            ge = -D2*vec(x1)+M2*vec(x2)
            add!(problem.assembly.g, sdofs, Q2'*ge)
            ce = vec(la1) + ge
            add!(problem.assembly.c, sdofs, Q2'*ce)

        end # master elements done

        if "contact area" in props.store_fields
            update!(slave_element, "contact area", time => contact_area)
        end

        if "contact error" in props.store_fields
            update!(slave_element, "contact error", time => contact_error)
        end

    end # slave elements done, contact virtual work ready

    S = sort(collect(keys(normals))) # slave element nodes
    weighted_gap = Dict{Int64, Vector{Float64}}()
    contact_pressure = Dict{Int64, Vector{Float64}}()
    complementarity_condition = Dict{Int64, Vector{Float64}}()
    is_active = Dict{Int64, Int}()
    is_inactive = Dict{Int64, Int}()
    is_slip = Dict{Int64, Int}()
    is_stick = Dict{Int64, Int}()

    la = problem.assembly.la
    ndofs = length(la)

    C1 = sparse(problem.assembly.C1)
    C2 = sparse(problem.assembly.C2, ndofs, ndofs)
    D = spzeros(ndofs, ndofs)
    c = full(problem.assembly.c, ndofs, 1)
    g = full(problem.assembly.g, ndofs, 1)

    # active / inactive node detection
    for j in S
        dofs = [2*(j-1)+1, 2*(j-1)+2]
        weighted_gap[j] = g[dofs]

        if length(la) != 0
            p = dot(normals[j], la[dofs])
            t = dot(tangents[j], la[dofs])
            contact_pressure[j] = [p, t]
        else
            contact_pressure[j] = [0.0, 0.0]
        end

        #complementarity_condition[j] = contact_pressure[j] - weighted_gap[j]
        complementarity_condition[j] = c[dofs]
        if complementarity_condition[j][1] < 0
            is_inactive[j] = 1
            is_active[j] = 0
            is_slip[j] = 0
            is_stick[j] = 0
        else
            is_inactive[j] = 0
            is_active[j] = 1
            is_slip[j] = 1
            is_stick[j] = 0
        end
    end

    if "weighted gap" in props.store_fields
        update!(slave_elements, "weighted gap", time => weighted_gap)
    end
    if "contact pressure" in props.store_fields
        update!(slave_elements, "contact pressure", time => contact_pressure)
    end
    if "complementarity condition" in props.store_fields
        update!(slave_elements, "complementarity condition", time => complementarity_condition)
    end
    if "active nodes" in props.store_fields
        update!(slave_elements, "active nodes", time => is_active)
    end
    if "inactive nodes" in props.store_fields
        update!(slave_elements, "inactive nodes", time => is_inactive)
    end
    if "stick nodes" in props.store_fields
        update!(slave_elements, "stick nodes", time => is_stick)
    end
    if "slip nodes" in props.store_fields
        update!(slave_elements, "slip nodes", time => is_slip)
    end

#   info("# | active | inactive | stick | slip | gap | pres | comp")
#   for j in S
#       str1 = "$j | $(is_active[j]) | $(is_inactive[j]) | $(is_stick[j]) | $(is_slip[j]) | "
#       str2 = "$(round(weighted_gap[j], 3)) | $(round(contact_pressure[j], 3)) | $(round(complementarity_condition[j], 3))"
#       info(str1 * str2)
#   end

    # solve variational inequality
    
    # constitutive modelling in tangent direction, frictionless contact
    for j in S
        dofs = [2*(j-1)+1, 2*(j-1)+2]
        if (is_active[j] == 1) && (is_slip[j] == 1)
#           info("$j is in active/slip, removing tangential constraint $(dofs[2])")
            C2[dofs[2],:] = 0.0
            g[dofs[2]] = 0.0
            D[dofs[2], dofs] = tangents[j]
        end
    end

    # remove inactive nodes from assembly
    for j in S
        dofs = [2*(j-1)+1, 2*(j-1)+2]
        if is_inactive[j] == 1
#           info("$j is inactive, removing dofs $dofs")
            C1[dofs,:] = 0.0
            C2[dofs,:] = 0.0
            D[dofs,:] = 0.0
            g[dofs,:] = 0.0
        end
    end

    problem.assembly.C1 = C1
    problem.assembly.C2 = C2
    problem.assembly.D = D
    problem.assembly.g = g

end

