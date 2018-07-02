# This file is a part of JuliaFEM.
# License is MIT: see https://github.com/JuliaFEM/MortarContact2DAD.jl/blob/master/LICENSE

mutable struct Mortar2DAD <: BoundaryProblem
    master_elements :: Vector{Element}
end

function Mortar2DAD()
    return Mortar2DAD([])
end

function FEMBase.add_elements!(::Problem{Mortar2DAD}, ::Any)
    error("use `add_slave_elements!` and `add_master_elements!` to add ",
          "elements to the Mortar2D problem.")
end

function FEMBase.add_slave_elements!(problem::Problem{Mortar2DAD}, elements)
    for element in elements
        push!(problem.elements, element)
    end
end

function FEMBase.add_master_elements!(problem::Problem{Mortar2DAD}, elements)
    for element in elements
        push!(problem.properties.master_elements, element)
    end
end

function FEMBase.get_slave_elements(problem::Problem{Mortar2DAD})
    return problem.elements
end

function FEMBase.get_master_elements(problem::Problem{Mortar2DAD})
    return problem.properties.master_elements
end

function get_slave_dofs(problem::Problem{Mortar2DAD})
    dofs = Int64[]
    for element in get_slave_elements(problem)
        append!(dofs, get_gdofs(problem, element))
    end
    return sort(unique(dofs))
end

function get_master_dofs(problem::Problem{Mortar2DAD})
    dofs = Int64[]
    for element in get_master_elements(problem)
        append!(dofs, get_gdofs(problem, element))
    end
    return sort(unique(dofs))
end

function project_from_master_to_slave_ad(slave_element::Element{E}, x1_, n1_, x2, time;
                    tol=1.0e-9, max_iterations=5) where {E<:MortarElements2D}

    x1(xi1) = interpolate(vec(get_basis(slave_element, [xi1], time)), x1_)
    dx1(xi1) = interpolate(vec(get_dbasis(slave_element, [xi1], time)), x1_)
    n1(xi1) = interpolate(vec(get_basis(slave_element, [xi1], time)), n1_)
    dn1(xi1) = interpolate(vec(get_dbasis(slave_element, [xi1], time)), n1_)
    cross2(a, b) = cross([a; 0], [b; 0])[3]
    R(xi1) = cross2(x1(xi1)-x2, n1(xi1))
    dR(xi1) = cross2(dx1(xi1), n1(xi1)) + cross2(x1(xi1)-x2, dn1(xi1))

    xi1 = 0.0
    dxi1 = 0.0
    for i=1:max_iterations
        dxi1 = -R(xi1)/dR(xi1)
        xi1 += dxi1
        if norm(dxi1) < tol
            return xi1
        end
    end

    info("x1 = $x1")
    info("n1 = $n1")
    info("x2 = $x2")
    info("xi1 = $xi1, dxi1 = $dxi1")
    info("-R(xi1) = $(-R(xi1))")
    info("dR(xi1) = $(dR(xi1))")
    error("find projection from master to slave: did not converge")

end

function project_from_slave_to_master_ad(
    master_element::Element{E}, x1, n1, x2_, time;
    tol=1.0e-10, max_iterations=20) where E<:MortarElements2D

    x2(xi2) = interpolate(vec(get_basis(master_element, [xi2], time)), x2_)
    dx2(xi2) = interpolate(vec(get_dbasis(master_element, [xi2], time)), x2_)
    cross2(a, b) = cross([a; 0], [b; 0])[3]
    R(xi2) = cross2(x2(xi2)-x1, n1)
    dR(xi2) = cross2(dx2(xi2), n1)

    xi2 = 0.0
    dxi2 = 0.0
    for i=1:max_iterations
        dxi2 = -R(xi2) / dR(xi2)
        xi2 += dxi2
        if norm(dxi2) < tol
            return xi2
        end
    end

    error("find projection from slave to master: did not converge, last val: $xi2 and $dxi2")

end

""" 2d mesh tie using ForwardDiff.

Construct .. + fc*la and C(d,la)=0

"""
function FEMBase.assemble_elements!(problem::Problem{Mortar2DAD}, assembly::Assembly,
                                    elements::Vector{Element{Seg2}}, time::Float64)

    props = problem.properties
    field_dim = get_unknown_field_dimension(problem)
    field_name = get_parent_field_name(problem)
    slave_elements = get_slave_elements(problem)

    function calculate_interface(x::Vector)

        ndofs = round(Int, length(x)/2)
        nnodes = round(Int, ndofs/field_dim)
        u = reshape(x[1:ndofs], field_dim, nnodes)
        la = reshape(x[ndofs+1:end], field_dim, nnodes)
        fc = zeros(u)
        gap = zeros(u)
        C = zeros(la)

        S = Set{Int64}()
        # 1. update nodal normals for slave elements
        tangents = zeros(u)
        for element in slave_elements
            conn = get_connectivity(element)
            push!(S, conn...)
            X1 = element("geometry", time)
            u1 = ((u[:,i] for i in conn)...)
            x1 = map(+, X1, u1)
            dN = get_dbasis(element, [0.0], time)
            tangent = sum([kron(dN[:,i], x1[i]') for i=1:length(x1)])
            for nid in conn
                tangents[:,nid] += tangent[:]
            end
        end

        Q = [0.0 -1.0; 1.0 0.0]
        normals = zeros(u)
        for j in S
            tangents[:,j] /= norm(tangents[:,j])
            normals[:,j] = Q*tangents[:,j]
        end

        #update!(slave_elements, "normal", time => Dict(j => normals[:,j] for j in S))
        #update!(slave_elements, "tangent", time => Dict(j => tangents[:,j] for j in S))

        # 2. loop all slave elements
        for slave_element in slave_elements

            nsl = length(slave_element)
            slave_element_nodes = get_connectivity(slave_element)
            X1 = slave_element("geometry", time)
            u1 = ((u[:,i] for i in slave_element_nodes)...)
            x1 = map(+, X1, u1)
            la1 = ((la[:,i] for i in slave_element_nodes)...)
            n1 = ((normals[:,i] for i in slave_element_nodes)...)


            # 3. loop all master elements
            for master_element in get_master_elements(problem)

                nm = length(master_element)
                master_element_nodes = get_connectivity(master_element)
                X2 = master_element("geometry", time)
                u2 = ((u[:,i] for i in master_element_nodes)...)
                x2 = map(+, X2, u2)

                # 3.1 calculate segmentation
                xi1a = project_from_master_to_slave_ad(slave_element, x1, n1, x2[1], time)
                xi1b = project_from_master_to_slave_ad(slave_element, x1, n1, x2[2], time)
#               xi1a = project_from_master_to_slave(slave_element, X2[1], time)
#               xi1b = project_from_master_to_slave(slave_element, X2[2], time)
                xi1 = clamp.([xi1a; xi1b], -1.0, 1.0)
                l = 1/2*abs(xi1[2]-xi1[1])
                isapprox(l, 0.0) && continue # no contribution in this master element

                De = zeros(nsl, nsl)
                Me = zeros(nsl, nsl)

                # 3.3. loop integration points of one integration segment and calculate
                # local mortar matrices
                for ip in get_integration_points(slave_element, 3)
                    detJ = slave_element(ip, time, Val{:detJ})
                    w = ip.weight*detJ*l
                    #dN = get_dbasis(slave_element, ip, time)
                    #j = sum([kron(dN[:,i], x1[i]') for i=1:length(x1)])
                    #w = ip.weight*norm(j)*l

                    xi = ip.coords[1]
                    xi_s = dot([1/2*(1-xi); 1/2*(1+xi)], xi1)
                    N1 = vec(get_basis(slave_element, xi_s, time))
                    Phi = N1
                    # project gauss point from slave element to master element in direction n_s
                    x_s = interpolate(N1, x1) # coordinate in gauss point
                    n_s = interpolate(N1, n1) # normal direction in gauss point
                    #xi_m = project_from_slave_to_master(master_element, X_s, n_s, time)
                    xi_m = project_from_slave_to_master_ad(master_element, x_s, n_s, x2, time)
                    N2 = vec(get_basis(master_element, xi_m, time))
                    x_m = interpolate(N2, x2)

                    la_s = interpolate(Phi, la1)
                    gn = dot(n_s, x_s-x_m)

                    u_s = interpolate(N1, u1)
                    u_m = interpolate(N2, u2)
                    X_s = interpolate(N1, X1)
                    X_m = interpolate(N2, X2)

                    fc[:,slave_element_nodes] += w*la_s*N1'
                    fc[:,master_element_nodes] -= w*la_s*N2'
                    #gap[1,slave_element_nodes] += w*gn*Phi'
                    gap[:,slave_element_nodes] += w*(u_s-u_m)*Phi'
                    # if props.adjust
                    #     G = w*(X_s-X_m)*Phi'
                    #     gap[:,slave_element_nodes] += G
                    # end
                end

            end # master elements done

        end # slave elements done, contact virtual work ready

        C = gap

        return vec([fc C])

    end

    # x doesn't mean deformed configuration here
    x = [problem.assembly.u; problem.assembly.la]
    ndofs = round(Int, length(x)/2)
    A = ForwardDiff.jacobian(calculate_interface, x)
    b = -calculate_interface(x)

    A = sparse(A)
    b = sparse(b)
    SparseArrays.droptol!(A, 1.0e-12)
    SparseArrays.droptol!(b, 1.0e-12)

    K = A[1:ndofs,1:ndofs]
    C1 = transpose(A[1:ndofs,ndofs+1:end])
    C2 = A[ndofs+1:end,1:ndofs]
    D = A[ndofs+1:end,ndofs+1:end]
    f = b[1:ndofs]
    g = b[ndofs+1:end]

    empty!(problem.assembly)
    problem.assembly.K = K
    problem.assembly.C1 = C1
    problem.assembly.C2 = C2
    problem.assembly.D = D
    problem.assembly.f = f
    problem.assembly.g = g

end
