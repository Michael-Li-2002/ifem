function [u,edge,eqn,info] = Maxwell(node,elem,bdFlag,pde,option,varargin)
%% MAXWELL Maxwell equation: lowest order edge element.
%
% u = Maxwell(node,elem,HB,pde,bdFlag) produces the lowest order edge
%   element approximation of the electric field of the time harmonic
%   Maxwell equation.
%
% curl(mu^(-1)curl u) - omega^2*epsilon u = J    in \Omega,  
%                                   n �\times u = n \times g_D  on \Gamma_D,
%                     n \times (mu^(-1)curl u) = n \times g_N  on \Gamma_N.
% 
% based on the weak formulation
%
% (mu^{-1}curl u, curl v) - (epsilon' u,v) = (J,v) - <n � g_N,v>_{\Gamma_N}.
%
% The data of the equation is enclosed in the pde structure:
%   - pde.mu      : permeability, i.e., magnetic constant/tensor
%   - pde.epsilon : a complex dielectric constant/tensor
%   - pde.omega   : wave number
%   - pde.J       : current density
%   - pde.g_D     : Dirichlet boundary condition
%   - pde.g_N     : Neumann boundary condition
%
% The mesh is given by (node,elem) and HB is needed for fast solvers. The
% boundary faces is specified by bdFlag; see <a href="matlab:ifem bddoc">bddoc</a>.
%
% The function Maxwell assembes the matrix equation (A-M)*u = b and solves
% it by the direct solver (small size dof <= 2e3) or the HX preconditioned
% Krylov iterative methods (large size dof > 2e3).
% 
% u = Maxwell(node,elem,HB,pde,bdFlag,option) specifies the solver options.
%   - option.solver == 'direct': the built in direct solver \ (mldivide)
%   - option.solver == 'mg':     multigrid-type solvers mg is used.
%   - option.solver == 'notsolve': the solution u = u_D. 
% The default setting is to use the direct solver for small size problems
% and multigrid solvers for large size problems. For more options on the
% multigrid solver mg, type help mg.
%
% [u,edge] = Maxwell(node,elem,pde,bdEdge) returns also the edge array
% which is essential for edge elements. 
%
% [u,edge,eqn] = Maxwell(node,elem,pde,bdEdge) returns also the equation
% structure eqn, which includes: 
% - eqn.A: matrix for differential operator;
% - eqn.M: mass matrix;
% - eqn.f: right hand side 
% - eqn.g: vector enclosed the Neumann boundary condition
%
% [u,edge,eqn,info] = Maxwell(node,elem,pde,bdEdge) returns also the
% information on the assembeling and solver, which includes:
% - info.assembleTime: time to assemble the matrix equation
% - info.solverTime:   time to solve the matrix equation
% - info.itStep:       number of iteration steps for the mg solver
% - info.error:        l2 norm of the residual b - A*u
% - info.flag:         flag for the mg solver.
%   flag = 0: converge within max iteration 
%   flag = 1: iterated maxIt times but did not converge
%   flag = 2: direct solver
%   flag = 3: no solve
%
% Example
%   cubeMaxwell
%
% See also Maxwell1, Maxwell2, cubeMaxwell, mgMaxwell
%
% Reference page in Help browser
%       <a href="matlab:ifem Maxwell3ND0femrate">Maxwell3ND0femrate</a> 
%
% Copyright (C) Long Chen. See COPYRIGHT.txt for details.


%% Set up optional input arguments
if ~exist('bdFlag','var'), bdFlag = []; end
if ~exist('option','var'), option = []; end
if nargin>=6
    HB = varargin{1};
else
    HB = [];
end

%% Sort elem to ascend ordering
elemold = elem;
[elem,bdFlag] = sortelem3(elem,bdFlag);

%% Construct Data Structure
[elem2dof,edge] = dof3edge(elem);
locEdge = [1 2; 1 3; 1 4; 2 3; 2 4; 3 4];
N = size(node,1);   NT = size(elem,1);  Ndof = size(edge,1);

%% Compute coefficients
if ~isfield(pde,'mu'), pde.mu = 1; end
if ~isempty(pde.mu) && isnumeric(pde.mu)
    mu = pde.mu;                % mu is an array
else                            % mu is a function
    center = (node(elem(:,1),:) + node(elem(:,2),:) + ...
              node(elem(:,3),:) + node(elem(:,4),:))/4;
    if isscalar(pde.mu(center(:,1)))
        mu = pde.mu(center);  
    elseif ismatrix(pde.mu(center(:,1)))
        temp = arrayfun(@(rowidx) pde.mu(center(rowidx,:))\eye(3), ...
            1:size(center,1), 'UniformOutput',0);
        muinv = cat(3,temp{:}); % concatenate the cells into array
        muinv = permute(muinv,[3,1,2]); % switch the element idx to the 1st dim
    else 
        warning('Input: mu is of unknown type, set mu=1.')
        mu = 1;
    end
end
if ~isfield(pde,'epsilon'), pde.epsilon = 1; end
if ~isempty(pde.epsilon) && isnumeric(pde.epsilon)
    epsilon = pde.epsilon;      % epsilon is an array
else                            % epsilon is a function
    center = (node(elem(:,1),:) + node(elem(:,2),:) + ...
              node(elem(:,3),:) + node(elem(:,4),:))/4;
    epsilon = pde.epsilon(center);              
end
if isfield(pde,'omega')
    omega = pde.omega;
else
    omega = 1;
end
epsilon = omega^2*epsilon; 

tstart = cputime;
%% Element-wise basis
% edge indices of 6 local bases: 
% [1 2], [1 3], [1 4], [2 3], [2 4], [3 4]
% phi = lambda_iDlambda_j - lambda_jDlambda_i;
% curl phi = 2*Dlambda_i � Dlambda_j;
[Dlambda,volume] = gradbasis3(node,elem);
curlPhi(:,:,6) = 2*mycross(Dlambda(:,:,3),Dlambda(:,:,4),2);
curlPhi(:,:,1) = 2*mycross(Dlambda(:,:,1),Dlambda(:,:,2),2);
curlPhi(:,:,2) = 2*mycross(Dlambda(:,:,1),Dlambda(:,:,3),2);
curlPhi(:,:,3) = 2*mycross(Dlambda(:,:,1),Dlambda(:,:,4),2);
curlPhi(:,:,4) = 2*mycross(Dlambda(:,:,2),Dlambda(:,:,3),2);
curlPhi(:,:,5) = 2*mycross(Dlambda(:,:,2),Dlambda(:,:,4),2);
DiDj = zeros(NT,4,4);
for i = 1:4
    for j = i:4        
        DiDj(:,i,j) = dot(Dlambda(:,:,i),Dlambda(:,:,j),2);
        DiDj(:,j,i) = DiDj(:,i,j);
    end
end

%% Assemble matrices
ii = zeros(21*NT,1); jj = zeros(21*NT,1); 
sA = zeros(21*NT,1); sM = zeros(21*NT,1);
index = 0;
for i = 1:6
    for j = i:6
        % local to global index map
        % curl-curl matrix
        switch ndims(mu)
            case 2 % scalar or element-wise constant
                Aij = dot(curlPhi(:,:,i),curlPhi(:,:,j),2).*volume./mu;
            case 3 % element-wise tensor
                muinvcurlPhii = sum(bsxfun(@times, muinv, curlPhi(:,:,i)), 2);
                Aij = dot(muinvcurlPhii,curlPhi(:,:,j),2).*volume;
        end
        ii(index+1:index+NT) = double(elem2dof(:,i)); 
        jj(index+1:index+NT) = double(elem2dof(:,j));
        sA(index+1:index+NT) = Aij;
        % mass matrix
        % locEdge = [1 2; 1 3; 1 4; 2 3; 2 4; 3 4];
        i1 = locEdge(i,1); i2 = locEdge(i,2);
        j1 = locEdge(j,1); j2 = locEdge(j,2);
        Mij = 1/20*volume.*( (1+(i1==j1))*DiDj(:,i2,j2) ...
                           - (1+(i1==j2))*DiDj(:,i2,j1) ...
                           - (1+(i2==j1))*DiDj(:,i1,j2) ...
                           + (1+(i2==j2))*DiDj(:,i1,j1));
        Mij = Mij.*epsilon;
        sM(index+1:index+NT) = Mij;
        index = index + NT;
    end
end
clear curlPhi % clear large size data
diagIdx = (ii == jj);   upperIdx = ~diagIdx;
A = sparse(ii(diagIdx),jj(diagIdx),sA(diagIdx),Ndof,Ndof);
AU = sparse(ii(upperIdx),jj(upperIdx),sA(upperIdx),Ndof,Ndof);
A = A + AU + AU';
M = sparse(ii(diagIdx),jj(diagIdx),sM(diagIdx),Ndof,Ndof);
MU = sparse(ii(upperIdx),jj(upperIdx),sM(upperIdx),Ndof,Ndof);
M = M + MU + MU';
% bigA = A + M;

%% Assemble right hand side
f = zeros(Ndof,1);
if ~isfield(pde,'J') || (isfield(pde,'J') && isreal(pde.J) && all(pde.J==0))
    pde.J = [];
end
if ~isfield(option,'fquadorder')
    option.fquadorder = 2;   % default order is 3
end
if isfield(pde,'J') && ~isempty(pde.J)
    [lambda,w] = quadpts3(option.fquadorder);
    nQuad = size(lambda,1);
    bt = zeros(NT,6);
    for p = 1:nQuad
        % quadrature points in the x-y-z coordinate
        pxyz = lambda(p,1)*node(elem(:,1),:) ...
             + lambda(p,2)*node(elem(:,2),:) ... 
             + lambda(p,3)*node(elem(:,3),:) ... 
             + lambda(p,4)*node(elem(:,4),:);
        Jp = pde.J(pxyz);
    %   locEdge = [1 2; 1 3; 1 4; 2 3; 2 4; 3 4];
        for k = 1:6
            i = locEdge(k,1); j = locEdge(k,2);
            % phi_k = lambda_iDlambda_j - lambda_jDlambda_i;
            phi_k = lambda(p,i)*Dlambda(:,:,j)-lambda(p,j)*Dlambda(:,:,i);
            rhs = dot(phi_k,Jp,2);
            bt(:,k) = bt(:,k) + w(p)*rhs;
        end
    end
    bt = bt.*repmat(volume,1,6);
    f = accumarray(elem2dof(:),bt(:),[Ndof 1]);
end
clear pxyz Jp bt rhs phi_k

%% Set up solver
if isempty(option) || ~isfield(option,'solver')    % no option.solver
    if Ndof <= 1e4  % Direct solver for small size systems
        option.solver = 'direct';
    else            % Multigrid-type  solver for large size systems
        option.solver = 'mg';
    end
end
solver = option.solver;

%% Assembeling corresponding matrices for HX preconditioner
if strcmp(solver,'mg')
    AP = sparse(N,N);  % AP = - div(mu^{-1}grad) + |Re(epsilon)| I
    BP = sparse(N,N);  % BP = - div(|Re(epsilon)|grad)   
    for i = 1:4
        for j = i:4
            switch ndims(mu)
                case 2
                    temp = DiDj(:,i,j).*volume;
                    Aij = 1./mu.*temp;
                case 3
                    muinvDi = sum(bsxfun(@times, muinv, Dlambda(:,:,i)), 2);
                    Aij = dot(muinvDi,Dlambda(:,:,j),2).*volume;
            end
            Bij = abs(real(epsilon)).*temp;
            Mij = 1/20*abs(real(epsilon)).*volume;
            if (j==i)
                AP = AP + sparse(elem(:,i),elem(:,j),Aij+2*Mij,N,N);
                BP = BP + sparse(elem(:,i),elem(:,j),Bij,N,N);            
            else
                AP = AP + sparse([elem(:,i);elem(:,j)],[elem(:,j);elem(:,i)],...
                                 [Aij+Mij; Aij+Mij],N,N);        
                BP = BP + sparse([elem(:,i);elem(:,j)],[elem(:,j);elem(:,i)],...
                                 [Bij; Bij],N,N);        
            end        
        end
    end
end
clear Aij Bij Mij DiDj

%% Boundary conditions
if ~isfield(pde,'g_D'), pde.g_D = []; end
if ~isfield(pde,'g_N'), pde.g_N = []; end
if ~isfield(pde,'g_R'), pde.g_R = []; end
if (isempty(pde.g_D) && isempty(pde.g_N) && isempty(pde.g_R))
    % no boundary data is given = homogenous Neumann boundary condition
    bdFlag = []; 
end

%% Part 1: Find Dirichlet dof and modify the matrix
% Find Dirichlet boundary dof: fixedDof
isBdEdge = [];
if isempty(bdFlag) && ~isempty(pde.g_D) && isempty(pde.g_N)
    % Dirichlet boundary condition only
    bdFlag = setboundary3(node,elem,'Dirichlet');
end
if ~isempty(bdFlag)
    % Find boundary edges and nodes
    isBdEdge = false(Ndof,1);
    isBdEdge(elem2dof(bdFlag(:,1) == 1,[4,5,6])) = true;
    isBdEdge(elem2dof(bdFlag(:,2) == 1,[2,3,6])) = true;
    isBdEdge(elem2dof(bdFlag(:,3) == 1,[1,3,5])) = true;
    isBdEdge(elem2dof(bdFlag(:,4) == 1,[1,2,4])) = true;
    bdEdge = edge(isBdEdge,:);
    isBdNode(bdEdge) = true;
end
% modify the matrix to include the Dirichlet boundary condition
if any(isBdEdge)  % contains Dirichlet boundary condition
    bdidx = zeros(Ndof,1); 
    bdidx(isBdEdge) = 1;
    Tbd = spdiags(bdidx,0,Ndof,Ndof);
    T = spdiags(1-bdidx,0,Ndof,Ndof);
    bigAD = T*(A-M)*T + Tbd;
    if strcmp(solver,'mg')
%     if strcmp(solver,'mg') || strcmp(solver,'amg')
        % modify the corresponding Poisson matrix
        bdidx = zeros(N,1); 
        bdidx(isBdNode) = 1;
        Tbd = spdiags(bdidx,0,N,N);
        T = spdiags(1-bdidx,0,N,N);
        AP = T*AP*T + Tbd;
        BP = T*BP*T + Tbd;
    end
else      % pure Neumann boundary condition
    bigAD = A - M;
    if ~strcmp(solver,'direct')
       BP = BP + 1e-8*speye(N);  % make B non-singular      
    end
end

%% Part 2: Find boundary edges and modify the load b
g = zeros(Ndof,1);
% Find Neumann boundary faces
if isempty(bdFlag) && (~isempty(pde.g_N) || ~isempty(pde.g_R))
    bdFlag = setboundary3(node,elem,'Neumann');
end
% non-zero Neumann boundary condition
if ~isempty(bdFlag) && ~isempty(pde.g_N)
    % face 1
    isBdElem = find(bdFlag(:,1) == 2); %#ok<*NASGU>
    face = [2 3 4]; face2locdof = [6 5 4];
    if ~isempty(isBdElem)
        bdb = bdfaceintegral(isBdElem,face,face2locdof);
        g = bdb;
    end
    % face 2
    isBdElem = find(bdFlag(:,2) == 2);
    face = [1 3 4]; face2locdof = [6 3 2];
    if ~isempty(isBdElem)
        bdb = bdfaceintegral(isBdElem,face,face2locdof);
        g = g + bdb; 
    end
    % face 3
    isBdElem = find(bdFlag(:,3) == 2);
    face = [1 2 4]; face2locdof = [5 3 1];
    if ~isempty(isBdElem)
        bdb = bdfaceintegral(isBdElem,face,face2locdof);
        g = g + bdb; 
    end
    % face 4
    isBdElem = find(bdFlag(:,4) == 2);
    face = [1 2 3]; face2locdof = [4 2 1];
    if ~isempty(isBdElem)
        bdb = bdfaceintegral(isBdElem,face,face2locdof);
        g = g + bdb;
    end
    f = f - g;
end
% nonzero Dirichlet boundary condition
u = zeros(Ndof,1);
if ~isempty(bdEdge) && ~isempty(pde.g_D) && ...
   ~(isnumeric(pde.g_D) && all(pde.g_D == 0))
    % else no bddof or g_D = 0 (no modification needed)
    if (isnumeric(pde.g_D) && length(pde.g_D) == Ndof)
        u(isBdEdge) = pde.g_D(isBdEdge);
    else
        u(isBdEdge) = edgeinterpolate(pde.g_D,node,bdEdge);
    end
    f = f - A*u + M*u;
    f(isBdEdge) = u(isBdEdge);
end
%% Remark
% The order of assign Neumann and Dirichlet boundary condition is
% important to get the right setting of the intersection of Dirichlet and
% Neumann faces.
    
%% Record assembling time
assembleTime = cputime - tstart;
if ~isfield(option,'printlevel'), option.printlevel = 1; end
if option.printlevel >= 2
    fprintf('Time to assemble matrix equation %4.2g s\n',assembleTime);
end

%% Solve the system of linear equations
if strcmp(solver,'none')
    eqn = struct('A',A,'M',M,'AP',AP,'BP',BP,'f',f,'g',g,'bigA',bigAD,'isBdEdge',isBdEdge); 
    info = [];
    return;
end
if strcmp(solver,'direct')
    % exact solver
    tstart = cputime;
    freeDof = find(~isBdEdge);
    u(freeDof) = bigAD(freeDof,freeDof)\f(freeDof);
    time = cputime - tstart; 
    err = norm(f - bigAD*u);
    info = struct('solverTime',time,'assembleTime',assembleTime,'itStep',0, ...
                  'stopErr',0, 'error',err,'flag',2);      
    if (nargin > 4) && isfield(option,'printlevel') && (option.printlevel >= 1)
        fprintf('#dof: %8.0u, Direct solver %4.2g \n',length(f),time);
    end
elseif strcmp(solver,'amg')
%     u0 = edgeinterpolate(pde.g_D,node,edge);
    u0 = u;
    option.x0 = u0;
    option.alpha = ones(Ndof,1);
    option.beta = ones(Ndof,1);
%     option.isBdEdge = isBdEdge;
    option.outsolver = 'cg';    
    [u,info] = amgMaxwell(bigAD,f,node,edge,option);
else
    u0 = u;
    option.x0 = u0;
    option.outsolver = 'cg';
    [u,info] = mgMaxwell(bigAD,f,AP,BP,node,elemold,edge,HB,isBdEdge,option);    
end

%% Output
eqn = struct('A',A,'M',M,'f',f,'g',g,'bigA',bigAD,'isBdEdge',isBdEdge);
info.assembleTime = assembleTime;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% subfunctions bdfaceintegral
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    function bdb = bdfaceintegral(isBdElem,face,face2locdof)
    %% Compute boundary surface integral of lowest order edge element.
    %  bdb(k) = \int_{face} (n�g_N, phi_k) dS

    %% Compute scaled normal
    faceIdx = true(4,1);
    faceIdx(face) = false;
    normal = -3*repmat(volume(isBdElem),1,3).*Dlambda(isBdElem,:,faceIdx);

    %% Data structure
    tetLocEdge = [1 2; 1 3; 1 4; 2 3; 2 4; 3 4]; % edge of a tetrahedral [1 2 3 4]
    face2locEdge = [2 3; 1 3; 1 2]; % edge of the face [1 2 3]

    %% Compute surface integral
    Nbd = length(isBdElem);
    bt = zeros(Nbd,3);
    idx = zeros(Nbd,3,'int32');
    [lambda,w] = quadpts(3); % quadrature order is 3
    nQuad = size(lambda,1);
    for pp = 1:nQuad
        % quadrature points in the x-y-z coordinate
        pxyz = lambda(pp,1)*node(elem(isBdElem,face(1)),:) ...
             + lambda(pp,2)*node(elem(isBdElem,face(2)),:) ... 
             + lambda(pp,3)*node(elem(isBdElem,face(3)),:);
        gNp = pde.g_N(pxyz,normal);    
        for s = 1:3
            kk = face2locdof(s);
            phi_k = lambda(pp,face2locEdge(s,1))*Dlambda(isBdElem,:,tetLocEdge(kk,2)) ...
                  - lambda(pp,face2locEdge(s,2))*Dlambda(isBdElem,:,tetLocEdge(kk,1));
            rhs = dot(phi_k,gNp,2);
            bt(:,s) = bt(:,s) + w(pp)*rhs; % area is included in normal; see line 28
            idx(:,s) = elem2dof(isBdElem,kk);
        end
    end
    %% Distribute to DOF
    bdb = accumarray(idx(:),bt(:),[Ndof 1]);        
    end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
end